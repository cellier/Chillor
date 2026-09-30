"""Confirm the narrowest read rule that lets the interpreter start.

The bisect showed the interpreter needs /private/var/folders, yet the failing
profile already allowed the run directory inside it. The remaining candidate is
the per-user darwin CACHE directory (a sibling of TMPDIR), where dyld keeps its
closures — TMPDIR is overridden for the child, the cache dir is not.

Run: Resources/AgentPython/bin/python3 Tests/sandbox_confirm.py
"""
import pathlib, shutil, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'Resources/AgentTools'))
import sandbox

PY_EXE = sys.executable
HOME = sandbox.python_home(PY_EXE)
PROGRAM = "from PIL import Image\nImage.new('RGB',(4,4)).save('p.png')\nprint('INSIDE-OK')\n"


def darwin_dirs():
    out = {}
    for name in ('DARWIN_USER_TEMP_DIR', 'DARWIN_USER_CACHE_DIR'):
        try:
            value = subprocess.run(['/usr/bin/getconf', name], capture_output=True,
                                   text=True, timeout=10).stdout.strip()
            if value:
                out[name] = str(pathlib.Path(value).resolve())
        except Exception:
            pass
    return out


DIRS = darwin_dirs()
CACHE = DIRS.get('DARWIN_USER_CACHE_DIR', '')
BASE = str(pathlib.Path(CACHE).parent) if CACHE else ''

print('interpreter        : '+PY_EXE)
for key, value in DIRS.items():
    print('%-19s: %s' % (key.replace('DARWIN_USER_', '').lower(), value))
print()


def attempt(label, extra_reads):
    directory = tempfile.mkdtemp(prefix='sbx-cf-')
    run_dir = str(pathlib.Path(directory).resolve())
    try:
        reads = '\n'.join('  (subpath "%s")' % p for p in
                          ['/usr', '/System', '/Library', HOME, run_dir] + list(extra_reads))
        text = (f'(version 1)\n(deny default)\n(deny network*)\n'
                f'(allow process-fork)\n(allow process-exec*)\n(allow file-map-executable)\n'
                f'(allow file-read-metadata)\n(allow sysctl-read)\n(allow mach-lookup)\n'
                f'(allow ipc-posix-shm*)\n(allow signal)\n'
                f'(allow file-read*\n{reads}\n'
                f'  (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom"))\n'
                f'(allow file-write* (subpath "{run_dir}") (literal "/dev/null"))\n')
        program = pathlib.Path(run_dir)/'program.py'
        program.write_text(PROGRAM, encoding='utf-8')
        sb = pathlib.Path(run_dir)/'p.sb'
        sb.write_text(text, encoding='utf-8')
        done = subprocess.run([sandbox.SANDBOX_EXEC, '-f', str(sb), PY_EXE, '-I', str(program)],
                              cwd=run_dir, capture_output=True, timeout=90,
                              env={'PATH': '/usr/bin:/bin', 'TMPDIR': run_dir, 'HOME': run_dir,
                                   'PYTHONDONTWRITEBYTECODE': '1'})
        good = done.returncode == 0 and b'INSIDE-OK' in done.stdout
        print(('  PASS  ' if good else '  BREAK ')+label+('' if good else '   exit=%s' % done.returncode))
        return good
    finally:
        shutil.rmtree(directory, ignore_errors=True)


print('narrowest first — the first PASS is the rule to ship')
results = []
if CACHE:
    results.append(('darwin cache dir only', attempt('+ '+CACHE, [CACHE])))
if BASE:
    results.append(('darwin per-user base', attempt('+ '+BASE, [BASE])))
results.append(('all of /private/var/folders', attempt('+ /private/var/folders', ['/private/var/folders'])))

print()
winner = next((name for name, good in results if good), None)
if winner:
    print('ship: '+winner)
else:
    print('none of these were enough — the missing read is elsewhere; send this output.')
