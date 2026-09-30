"""Ask the kernel which paths the interpreter actually needs.

Run on the Mac:
    Resources/AgentPython/bin/python3 Tests/sandbox_trace.py

Runs the interpreter under (allow default) with seatbelt's trace mode, which
records every operation it attempted, then prints the reads that the shipped
profile does NOT yet cover. Those are exactly the rules to add — no guessing.

Falls back to an additive ladder if trace is unavailable on this system.
"""
import os, pathlib, re, shutil, subprocess, sys, tempfile
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'Resources/AgentTools'))
import sandbox

PY_EXE = sys.executable
HOME = sandbox.python_home(PY_EXE)

PROGRAM = (
    "open('probe.txt','w').write('ok')\n"
    "from PIL import Image\n"
    "Image.new('RGB',(4,4)).save('probe.png')\n"
    "import json, zipfile, ssl, sqlite3, datetime\n"
    "print('INSIDE-OK')\n"
)

# What the shipped profile already grants read access to.
COVERED = ['/usr', '/System', '/Library', HOME]


def run_under(profile_text, run_dir, extra_env=None):
    program = pathlib.Path(run_dir)/'program.py'
    program.write_text(PROGRAM, encoding='utf-8')
    env = {'PATH': '/usr/bin:/bin', 'TMPDIR': run_dir, 'HOME': run_dir,
           'PYTHONDONTWRITEBYTECODE': '1'}
    env.update(extra_env or {})
    sb = pathlib.Path(run_dir)/'profile.sb'
    sb.write_text(profile_text, encoding='utf-8')
    return subprocess.run([sandbox.SANDBOX_EXEC, '-f', str(sb), PY_EXE, '-I', str(program)],
                          cwd=run_dir, capture_output=True, timeout=90, env=env)


def trace_paths():
    directory = tempfile.mkdtemp(prefix='sbx-trace-')
    resolved = str(pathlib.Path(directory).resolve())
    out = pathlib.Path(resolved)/'trace.sb'
    try:
        done = run_under(f'(version 1)\n(allow default)\n(trace "{out}")\n', resolved)
        if b'INSIDE-OK' not in done.stdout:
            print('  the traced run itself failed:')
            print('  '+done.stderr.decode('utf-8', 'replace')[:400])
        if not out.is_file():
            return None
        return out.read_text(encoding='utf-8', errors='replace')
    except Exception as error:
        print('  trace unavailable: '+repr(error)[:200])
        return None
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def summarise(trace):
    wanted = Counter()
    for line in trace.splitlines():
        if 'file-read' not in line and 'file*' not in line:
            continue
        for path in re.findall(r'"((?:/|\$)[^"]*)"', line):
            if any(path == c or path.startswith(c+'/') for c in COVERED):
                continue
            if path.startswith(('/private/var/folders', '/dev/null', '/dev/random', '/dev/urandom')):
                continue
            # Group to the first two components so the suggestion stays narrow but usable.
            parts = [p for p in path.split('/') if p]
            wanted['/'+'/'.join(parts[:2]) if len(parts) > 1 else '/'+parts[0] if parts else path] += 1
    return wanted


CANDIDATES = ['/dev', '/private/var/db', '/private/etc', '/private/var/select',
              '/private/tmp', '/opt', '/AppleInternal', '/Applications']


def ladder():
    """Additive fallback: grant one candidate area at a time until it runs."""
    granted = []
    for extra in [None]+CANDIDATES:
        if extra:
            granted.append(extra)
        directory = tempfile.mkdtemp(prefix='sbx-add-')
        resolved = str(pathlib.Path(directory).resolve())
        try:
            reads = '\n'.join(f'  (subpath "{p}")' for p in COVERED+granted)
            text = (f'(version 1)\n(deny default)\n(deny network*)\n'
                    f'(allow process-fork)\n(allow process-exec*)\n(allow file-map-executable)\n'
                    f'(allow file-read-metadata)\n(allow sysctl-read)\n(allow mach-lookup)\n'
                    f'(allow ipc-posix-shm*)\n(allow signal)\n'
                    f'(allow file-read*\n{reads}\n  (subpath "{resolved}")\n'
                    f'  (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom"))\n'
                    f'(allow file-write* (subpath "{resolved}") (literal "/dev/null"))\n')
            done = run_under(text, resolved)
            label = 'baseline' if not granted else '+ '+', '.join(granted)
            good = done.returncode == 0 and b'INSIDE-OK' in done.stdout
            print(('  PASS  ' if good else '  BREAK ')+label+('   exit=%s' % done.returncode if not good else ''))
            if good:
                return granted
        finally:
            shutil.rmtree(directory, ignore_errors=True)
    return None


print('interpreter : '+PY_EXE)
print('python home : '+HOME+'\n')

print('A. seatbelt trace — what the interpreter actually opens')
trace = trace_paths()
if trace:
    wanted = summarise(trace)
    if wanted:
        print('   read paths not covered by the shipped profile, most frequent first:')
        for path, count in wanted.most_common(25):
            print('     %-40s %d' % (path, count))
    else:
        print('   nothing outside the covered set — the read rules are not the problem')
    pathlib.Path('work/sandbox-trace.sb').parent.mkdir(exist_ok=True)
    pathlib.Path('work/sandbox-trace.sb').write_text(trace, encoding='utf-8')
    print('   full generated profile saved to work/sandbox-trace.sb')
else:
    print('   trace produced nothing on this system\n')

print('\nB. additive ladder — the minimal extra areas that let it start')
needed = ladder()
print()
if needed is None:
    print('nothing in the candidate list was enough; send section A output.')
elif not needed:
    print('the baseline already works — the shipped profile differs elsewhere '
          '(most likely the restricted process-exec* rule).')
else:
    print('minimal extra read areas needed: '+', '.join(needed))
