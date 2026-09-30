"""Find which sandbox rule stops the interpreter from running.

Run on the Mac:
    Resources/AgentPython/bin/python3 Tests/sandbox_diagnose.py

Climbs from "no sandbox" to the real profile, one restriction at a time, and
prints the full stderr of the first rung that breaks. The last rung that works
tells you exactly which rule is at fault. Nothing here is used at runtime.
"""
import os, pathlib, shutil, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'Resources/AgentTools'))
import sandbox

PY_EXE = sys.executable
HOME = sandbox.python_home(PY_EXE)

PROGRAM = (
    "import sys\n"
    "open('probe.txt','w').write('ok')\n"
    "from PIL import Image\n"
    "Image.new('RGB',(4,4)).save('probe.png')\n"
    "print('INSIDE-OK', sys.version.split()[0])\n"
)


def rungs(run_dir):
    common = f'''(allow process-fork)
(allow process-exec*)
(allow file-map-executable)
(allow file-read-metadata)
(allow sysctl-read)
(allow mach-lookup)
(allow ipc-posix-shm*)
(allow signal)'''
    return [
        ('0. no sandbox at all (control)', None),
        ('1. sandbox-exec with (allow default)', '(version 1)\n(allow default)\n'),
        ('2. allow default, deny only network', '(version 1)\n(allow default)\n(deny network*)\n'),
        ('3. deny default + broad allows, network denied',
         f'(version 1)\n(deny default)\n(deny network*)\n{common}\n'
         '(allow file-read*)\n(allow file-write*)\n'),
        ('4. as 3, but writes confined to the run directory',
         f'(version 1)\n(deny default)\n(deny network*)\n{common}\n'
         f'(allow file-read*)\n(allow file-write* (subpath "{run_dir}"))\n'),
        ('5. as 4, but reads confined to system + interpreter + run dir',
         f'(version 1)\n(deny default)\n(deny network*)\n{common}\n'
         f'(allow file-read* (subpath "/usr") (subpath "/System") (subpath "/Library")\n'
         f'  (subpath "{HOME}") (subpath "{run_dir}")\n'
         f'  (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom"))\n'
         f'(allow file-write* (subpath "{run_dir}") (literal "/dev/null"))\n'),
        ('6. as 5, but process-exec limited to the interpreter',
         f'(version 1)\n(deny default)\n(deny network*)\n'
         f'(allow process-fork)\n(allow process-exec* (subpath "{HOME}"))\n'
         f'(allow file-map-executable)\n(allow file-read-metadata)\n(allow sysctl-read)\n'
         f'(allow mach-lookup)\n(allow ipc-posix-shm*)\n(allow signal)\n'
         f'(allow file-read* (subpath "/usr") (subpath "/System") (subpath "/Library")\n'
         f'  (subpath "{HOME}") (subpath "{run_dir}")\n'
         f'  (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom"))\n'
         f'(allow file-write* (subpath "{run_dir}") (literal "/dev/null"))\n'),
        ('7. the shipped profile', sandbox.profile(run_dir, HOME)),
    ]


def attempt(label, text, run_dir):
    program = pathlib.Path(run_dir)/'program.py'
    program.write_text(PROGRAM, encoding='utf-8')
    env = {'PATH': '/usr/bin:/bin', 'TMPDIR': run_dir, 'HOME': run_dir,
           'PYTHONDONTWRITEBYTECODE': '1'}
    if text is None:
        command = [PY_EXE, '-I', str(program)]
    else:
        sb = pathlib.Path(run_dir)/'profile.sb'
        sb.write_text(text, encoding='utf-8')
        command = [sandbox.SANDBOX_EXEC, '-f', str(sb), PY_EXE, '-I', str(program)]
    done = subprocess.run(command, cwd=run_dir, capture_output=True, timeout=60, env=env)
    good = done.returncode == 0 and b'INSIDE-OK' in done.stdout
    print(('  PASS  ' if good else '  BREAK ')+label)
    if not good:
        err = done.stderr.decode('utf-8', 'replace').strip()
        out = done.stdout.decode('utf-8', 'replace').strip()
        print('        exit=%s' % done.returncode)
        for line in (err or out or '(no output)').splitlines()[:12]:
            print('        | '+line)
    return good


print('interpreter : '+PY_EXE)
print('python home : '+HOME)
print('sandbox-exec: '+('present' if os.path.exists(sandbox.SANDBOX_EXEC) else 'MISSING')+'\n')

first_break = None
for label, text in rungs('__RUN__'):
    directory = tempfile.mkdtemp(prefix='sbx-diag-')
    resolved = str(pathlib.Path(directory).resolve())
    try:
        body = text.replace('__RUN__', resolved) if text else None
        if not attempt(label, body, resolved) and first_break is None:
            first_break = label
    finally:
        shutil.rmtree(directory, ignore_errors=True)

print()
if first_break is None:
    print('every rung passed: the shipped profile works here.')
    print('re-run  Resources/AgentPython/bin/python3 Resources/AgentTools/sandbox.py')
else:
    print('first failure: '+first_break)
    print('the rung above it is the last one that worked, so the rule added at this')
    print('step is the one to adjust. Add only the minimal allow needed; never widen')
    print('file-write* or network*.')
