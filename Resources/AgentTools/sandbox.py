"""Sandboxed Python execution for Chillor.

Isolation is layered, because no single layer here is guaranteed:

  1. Seatbelt (sandbox-exec) with a deny-by-default SBPL profile: no network,
     reads limited to the system and the bundled interpreter, writes limited to
     one throwaway run directory.
  2. Hard resource limits set irreversibly by a prelude before any user code
     runs, so the limits cannot be raised back.
  3. Wall-clock timeout with a process-group kill, and capped output.
  4. The run directory is NOT the task workspace. Declared inputs are copied in
     and produced files are copied back out through the caller's validated
     commit path, so a file-level escape still cannot touch the user's originals.
  5. A runtime probe that asserts escapes actually fail on this machine. If the
     probe cannot prove isolation, the caller must not expose the tool.

sandbox-exec is deprecated by Apple but still enforced by the kernel; Apple ships
no supported replacement for non-App-Store process sandboxing. Layer 5 exists
precisely because that could change under us: the day it stops working, the
probe fails and the capability disappears instead of silently running unconfined.
"""
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

SANDBOX_EXEC = '/usr/bin/sandbox-exec'
DEFAULT_TIMEOUT = 60
MAX_TIMEOUT = 180
DEFAULT_MEMORY_MB = 1024
MAX_OUTPUT = 20000
PROBE_TTL = 24*3600


def readable_roots(executable):
    """Directories the interpreter needs to read: its own tree, symlink or not."""
    path = pathlib.Path(executable)
    roots = {path.parent.parent if path.parent.name == 'bin' else path.parent}
    resolved = path.resolve()
    roots.add(resolved.parent.parent if resolved.parent.name == 'bin' else resolved.parent)
    for attribute in ('base_prefix', 'prefix', 'base_exec_prefix', 'exec_prefix'):
        value = getattr(sys, attribute, '')
        # Only trust the running interpreter's own view when it IS this interpreter.
        if value and pathlib.Path(sys.executable).resolve() == resolved:
            roots.add(pathlib.Path(value))
    ordered = sorted({str(r) for r in roots}, key=len)
    return [r for i, r in enumerate(ordered)
            if not any(r.startswith(o+'/') for o in ordered[:i])]


# What the sandbox is actually protecting: the person's files and the network.
# System files being readable is not a meaningful leak, and locking reads down to
# a hand-listed set proved brittle — the interpreter needs scattered system paths
# that differ per machine. So: read broadly, then carve out everything personal.
PRIVATE = ['/Users', '/Volumes', '/private/var/root', '/Library/Keychains', '/private/etc/ssh']


def profile(run_dir, executable, style='carve'):
    """Deny by default; allow what an interpreter needs, minus anything personal.

    style 'carve'     - allow reads, deny personal areas, re-allow the interpreter.
    style 'enumerate' - list every top level except the personal ones. Fallback for
                        a system where a later allow does not override an earlier deny.
    """
    roots = readable_roots(executable)
    interpreter = '\n'.join('  (subpath "%s")' % r for r in roots)
    execs = ' '.join('(subpath "%s")' % r for r in roots)
    private = '\n'.join('  (subpath "%s")' % p for p in PRIVATE)
    head = f'''(version 1)
(deny default)
(deny network*)
(allow process-fork)
(allow process-exec* {execs})
(allow file-map-executable)
(allow file-read-metadata)
(allow sysctl-read)
(allow mach-lookup)
(allow ipc-posix-shm*)
(allow signal)
'''
    if style == 'enumerate':
        tops = []
        for entry in sorted(pathlib.Path('/').iterdir()):
            name = '/'+entry.name
            if name.startswith('/.') or any(name == p or p.startswith(name+'/') for p in PRIVATE):
                continue
            tops.append('  (subpath "%s")' % name)
        reads = '(allow file-read*\n  (literal "/")\n'+'\n'.join(tops)+'\n'+interpreter+\
                f'\n  (subpath "{run_dir}"))\n'
    else:
        reads = ('(allow file-read*)\n'
                 '(deny file-read*\n'+private+')\n'
                 '(allow file-read*\n'+interpreter+f'\n  (subpath "{run_dir}"))\n')
    return head+reads+f'(allow file-write* (subpath "{run_dir}") (literal "/dev/null"))\n'


PRELUDE = '''import resource, sys, os
# Set soft AND hard limits: a lowered hard limit cannot be raised again, so the
# code that runs after this prelude cannot restore its own headroom.
for what, value in ((resource.RLIMIT_CPU, %(cpu)d),
                    (resource.RLIMIT_AS, %(mem)d),
                    (resource.RLIMIT_FSIZE, %(fsize)d),
                    (resource.RLIMIT_NOFILE, 256)):
    try:
        resource.setrlimit(what, (value, value))
    except (ValueError, OSError):
        pass
os.chdir(%(run_dir)r)
sys.argv = ['run_python']
source = open(%(code)r, encoding='utf-8').read()
exec(compile(source, 'run_python', 'exec'), {'__name__': '__main__'})
'''


def python_home(executable):
    """The bundled interpreter's root; everything it needs to run lives under it."""
    path = pathlib.Path(executable).resolve()
    return str(path.parent.parent if path.parent.name == 'bin' else path.parent)


def _launch(executable, run_dir, code_path, timeout, memory_mb, stdin_text='', style='carve'):
    run_dir = str(pathlib.Path(run_dir).resolve())
    sb = pathlib.Path(run_dir)/'.sandbox.sb'
    sb.write_text(profile(run_dir, executable, style), encoding='utf-8')
    runner = pathlib.Path(run_dir)/'.runner.py'
    runner.write_text(PRELUDE % {'cpu': max(1, int(timeout)), 'mem': memory_mb*1024*1024,
                                 'fsize': 64*1024*1024, 'run_dir': run_dir, 'code': str(code_path)},
                      encoding='utf-8')
    # -I isolates the interpreter: no environment influence, no user site-packages.
    command = [SANDBOX_EXEC, '-f', str(sb), executable, '-I', str(runner)]
    started = time.monotonic()
    process = subprocess.Popen(
        command, cwd=run_dir, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True,  # own process group, so a timeout kills descendants too
        env={'PATH': '/usr/bin:/bin', 'TMPDIR': run_dir, 'HOME': run_dir,
             'PYTHONDONTWRITEBYTECODE': '1', 'PYTHONHASHSEED': '0', 'LC_ALL': 'en_US.UTF-8'})
    try:
        out, err = process.communicate(stdin_text.encode(), timeout=timeout)
        timed_out = False
    except subprocess.TimeoutExpired:
        _kill_group(process)
        out, err = process.communicate()
        timed_out = True
    return {'exit_code': process.returncode, 'timed_out': timed_out,
            'stdout': out.decode('utf-8', 'replace'), 'stderr': err.decode('utf-8', 'replace'),
            'seconds': round(time.monotonic()-started, 2)}


def _kill_group(process):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(os.getpgid(process.pid), sig)
        except (ProcessLookupError, PermissionError):
            return
        try:
            process.wait(timeout=3)
            return
        except subprocess.TimeoutExpired:
            continue


def _run_snippet(executable, code, timeout=20, style='carve'):
    directory = tempfile.mkdtemp(prefix='chillor-probe-')
    try:
        source = pathlib.Path(directory)/'probe_code.py'
        source.write_text(code, encoding='utf-8')
        return _launch(executable, directory, source, timeout, 512, style=style)
    finally:
        shutil.rmtree(directory, ignore_errors=True)


PROBES = [
    ('the interpreter and its libraries still work',
     'import json,sys\nfrom PIL import Image\n'
     'Image.new("RGB",(4,4)).save("probe.png")\nprint(json.dumps({"ok":True}))', 'must_succeed'),
    ('writing inside the run directory works',
     'open("probe.txt","w").write("ok")\nprint("OK")', 'must_succeed'),
    ('writes outside the run directory are denied',
     'import pathlib,os\n'
     'p = pathlib.Path(os.path.expanduser("~/Desktop"))/"chillor-sandbox-escape-probe.txt"\n'
     'open(p,"w").write("escaped")\nprint("WROTE")', 'must_fail'),
    ('the home directory cannot be listed',
     'import os\nprint(len(os.listdir(os.path.expanduser("~/Desktop"))))', 'must_fail'),
    ('reading the user library is denied',
     'import os\nprint(len(os.listdir(os.path.expanduser("~/Library"))))', 'must_fail'),
    ('mounted volumes cannot be listed',
     'import os\nprint(len(os.listdir("/Volumes")))', 'must_fail'),
    ('outbound network is denied',
     'import socket\ns=socket.create_connection(("1.1.1.1",443),3)\nprint("CONNECTED")', 'must_fail'),
    ('dns resolution is denied',
     'import socket\nprint(socket.gethostbyname("example.com"))', 'must_fail'),
]


def probe(executable):
    """Assert that escapes actually fail here. Anything unproven means unavailable."""
    if not os.path.exists(SANDBOX_EXEC):
        return {'ok': False, 'reason': 'sandbox-exec is not present on this system', 'checks': []}
    if not os.access(executable, os.X_OK):
        return {'ok': False, 'reason': 'the bundled interpreter is missing', 'checks': []}

    for style in ('carve', 'enumerate'):
        report = _probe_style(executable, style)
        if report['ok']:
            return report
        if not report.get('cannot_start'):
            return report          # it started but an escape got through: do not retry
    return report


def _probe_style(executable, style):
    def attempt(name, code, expectation):
        try:
            result = _run_snippet(executable, code, style=style)
        except Exception as error:
            return {'check': name, 'expectation': expectation, 'passed': False,
                    'exit_code': None, 'detail': repr(error)[:300]}
        succeeded = result['exit_code'] == 0 and not result['timed_out']
        message = (result['stderr'].strip() or result['stdout'].strip())
        return {'check': name, 'expectation': expectation,
                'passed': succeeded if expectation == 'must_succeed' else not succeeded,
                'exit_code': result['exit_code'],
                'detail': (message.splitlines()[-1] if message else '')[:300]}

    # Positive controls first. If code cannot run at all, a "denied" escape is
    # not evidence of isolation, so the negative checks are reported unproven.
    checks = [attempt(n, c, e) for n, c, e in PROBES if e == 'must_succeed']
    if not all(check['passed'] for check in checks):
        for name, _code, expectation in PROBES:
            if expectation == 'must_fail':
                checks.append({'check': name, 'expectation': expectation, 'passed': False,
                               'inconclusive': True,
                               'detail': 'not evaluated: nothing ran inside the sandbox'})
        return {'ok': False, 'checks': checks, 'style': style, 'cannot_start': True,
                'reason': 'the sandbox could not run code at all, so isolation is unproven '
                          '(run Tests/sandbox_diagnose.py to find the rule at fault)'}
    checks += [attempt(n, c, e) for n, c, e in PROBES if e == 'must_fail']
    ok = all(check['passed'] for check in checks)
    return {'ok': ok, 'checks': checks, 'style': style,
            'reason': '' if ok else 'an escape attempt was not blocked'}


def available(executable, cache_path):
    """Cached probe. A stale or unreadable cache re-probes rather than assuming yes."""
    cache = pathlib.Path(cache_path)
    try:
        stamp = pathlib.Path(executable).stat().st_mtime_ns
        saved = json.loads(cache.read_text(encoding='utf-8'))
        if (saved.get('stamp') == stamp and saved.get('executable') == str(executable)
                and time.time()-saved.get('time', 0) < PROBE_TTL):
            return saved['result']
    except Exception:
        pass
    result = probe(executable)
    try:
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps({'stamp': pathlib.Path(executable).stat().st_mtime_ns,
                                     'executable': str(executable), 'time': time.time(),
                                     'result': result}), encoding='utf-8')
        cache.chmod(0o600)
    except Exception:
        pass
    return result


def run(code, run_dir, executable, timeout=DEFAULT_TIMEOUT, memory_mb=DEFAULT_MEMORY_MB):
    """Execute code in run_dir. The caller owns copying inputs in and results out."""
    if not isinstance(code, str) or not code.strip():
        raise ValueError('Provide Python source to run')
    if len(code) > 200000:
        raise ValueError('Program too large; write it to a file and run it in parts')
    timeout = max(1, min(MAX_TIMEOUT, int(timeout or DEFAULT_TIMEOUT)))
    run_dir = pathlib.Path(run_dir)
    run_dir.mkdir(parents=True, exist_ok=True)
    source = run_dir/'program.py'
    source.write_text(code, encoding='utf-8')
    before = {p: p.stat().st_mtime_ns for p in run_dir.rglob('*') if p.is_file()}
    result = _launch(executable, run_dir, source, timeout, memory_mb)
    produced = []
    internal = {'program.py', '.sandbox.sb', '.runner.py'}
    for path in sorted(run_dir.rglob('*')):
        if not path.is_file() or path.name in internal:
            continue
        if before.get(path) != path.stat().st_mtime_ns:
            produced.append({'name': str(path.relative_to(run_dir)), 'bytes': path.stat().st_size})
    for stream in ('stdout', 'stderr'):
        if len(result[stream]) > MAX_OUTPUT:
            result[stream] = result[stream][:MAX_OUTPUT]+'\n[output truncated]'
    result['produced'] = produced[:50]
    if result['timed_out']:
        result['error'] = f'Execution exceeded {timeout}s and was terminated.'
    elif result['exit_code'] != 0:
        result['error'] = 'The program exited with a non-zero status; see stderr.'
    return result


if __name__ == '__main__':
    # Diagnostic entry point: Resources/AgentPython/bin/python3 sandbox.py
    report = probe(sys.argv[1] if len(sys.argv) > 1 else sys.executable)
    for check in report['checks']:
        mark = 'ok   ' if check['passed'] else ('?    ' if check.get('inconclusive') else 'FAIL ')
        print(mark+check['check'])
        if not check['passed'] and check.get('detail'):
            print('        '+str(check['detail']))
    print(('\nsandbox usable (profile style: %s)' % report.get('style')
           if report['ok'] else '\nsandbox NOT usable: '+report['reason']))
    print("if a check fails, watch violations with:  log stream --predicate 'process == \"sandboxd\"' --info")
    sys.exit(0 if report['ok'] else 1)
