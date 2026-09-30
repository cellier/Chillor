"""Find the required read areas by subtraction, starting from a profile that works.

Run on the Mac:
    Resources/AgentPython/bin/python3 Tests/sandbox_bisect.py

Adding allows told us nothing, so this goes the other way: begin with the rung
that passed (reads unrestricted) and deny one area at a time. Whichever denial
breaks the interpreter is an area it genuinely needs. Also tests separately
whether a path containing spaces matches at all, since the dev tree lives in
".../Chillor mac app/" and every failing rung carried that path.
"""
import os, pathlib, shutil, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'Resources/AgentTools'))
import sandbox

PY_EXE = sys.executable
HOME = sandbox.python_home(PY_EXE)
PROGRAM = "from PIL import Image\nImage.new('RGB',(4,4)).save('p.png')\nprint('INSIDE-OK')\n"

COMMON = '''(allow process-fork)
(allow process-exec*)
(allow file-map-executable)
(allow file-read-metadata)
(allow sysctl-read)
(allow mach-lookup)
(allow ipc-posix-shm*)
(allow signal)'''


def run(profile_text, run_dir, program=PROGRAM, exe=PY_EXE):
    path = pathlib.Path(run_dir)/'program.py'
    path.write_text(program, encoding='utf-8')
    sb = pathlib.Path(run_dir)/'p.sb'
    sb.write_text(profile_text, encoding='utf-8')
    return subprocess.run([sandbox.SANDBOX_EXEC, '-f', str(sb), exe, '-I', str(path)],
                          cwd=run_dir, capture_output=True, timeout=90,
                          env={'PATH': '/usr/bin:/bin', 'TMPDIR': run_dir, 'HOME': run_dir,
                               'PYTHONDONTWRITEBYTECODE': '1'})


def base(run_dir, denies=''):
    return (f'(version 1)\n(deny default)\n(deny network*)\n{COMMON}\n'
            f'(allow file-read*)\n'
            f'(allow file-write* (subpath "{run_dir}") (literal "/dev/null"))\n{denies}')


AREAS = ['/System/Volumes', '/System/Cryptexes', '/System/Library/dyld', '/private/var/db',
         '/dev', '/private/etc', '/usr/lib', '/usr/share', '/Library', '/Users',
         '/private/var/folders', HOME]

print('interpreter : '+PY_EXE)
print('python home : '+HOME)
print('home has a space: '+('YES' if ' ' in HOME else 'no')+'\n')

print('A. control — reads unrestricted (this rung passed before)')
d = tempfile.mkdtemp(prefix='sbx-bi-'); r = str(pathlib.Path(d).resolve())
try:
    done = run(base(r), r)
    control = done.returncode == 0 and b'INSIDE-OK' in done.stdout
    print('   '+('PASS' if control else 'BREAK exit=%s' % done.returncode))
    if not control:
        print('   '+done.stderr.decode('utf-8', 'replace')[:300])
        print('\n   the control no longer passes; stop here and send this output.')
        sys.exit(1)
finally:
    shutil.rmtree(d, ignore_errors=True)

print('\nB. deny one area at a time — a BREAK means the interpreter needs that area')
required = []
for area in AREAS:
    d = tempfile.mkdtemp(prefix='sbx-bi-'); r = str(pathlib.Path(d).resolve())
    try:
        done = run(base(r, f'(deny file-read* (subpath "{area}"))\n'), r)
        good = done.returncode == 0 and b'INSIDE-OK' in done.stdout
        print('   %-28s %s' % (area, 'still runs' if good else 'BREAK  <- required'))
        if not good:
            required.append(area)
    finally:
        shutil.rmtree(d, ignore_errors=True)

print('\nC. does a path containing a space match at all?')
d = tempfile.mkdtemp(prefix='sbx-sp-'); r = str(pathlib.Path(d).resolve())
try:
    spaced = pathlib.Path(r)/'a b c'
    spaced.mkdir()
    (spaced/'secret.txt').write_text('SECRET', encoding='utf-8')
    probe = f"print(open({str(spaced/'secret.txt')!r}).read())\n"
    # Deny exactly that directory on top of unrestricted reads. If the deny works,
    # the read fails. If the file is still readable, spaced paths are not matching.
    done = run(base(r, f'(deny file-read* (subpath "{spaced}"))\n'), r, program=probe)
    out = done.stdout.decode('utf-8', 'replace')
    if 'SECRET' in out:
        print('   the deny had NO effect: a subpath containing spaces does not match')
        print('   -> this is the bug; the profile must not embed a spaced path directly')
    elif done.returncode != 0:
        print('   the deny took effect (read refused) -> spaced subpaths match correctly')
    else:
        print('   inconclusive: '+ (done.stderr.decode('utf-8','replace')[:200] or out[:200]))
finally:
    shutil.rmtree(d, ignore_errors=True)

print('\nD. same test using -D parameter substitution instead of a literal path')
d = tempfile.mkdtemp(prefix='sbx-pa-'); r = str(pathlib.Path(d).resolve())
try:
    spaced = pathlib.Path(r)/'a b c'
    spaced.mkdir()
    (spaced/'secret.txt').write_text('SECRET', encoding='utf-8')
    program = pathlib.Path(r)/'program.py'
    program.write_text(f"print(open({str(spaced/'secret.txt')!r}).read())\n", encoding='utf-8')
    sb = pathlib.Path(r)/'p.sb'
    sb.write_text(base(r, '(deny file-read* (subpath (param "TARGET")))\n'), encoding='utf-8')
    done = subprocess.run([sandbox.SANDBOX_EXEC, '-f', str(sb), '-D', f'TARGET={spaced}',
                           PY_EXE, '-I', str(program)], cwd=r, capture_output=True, timeout=60,
                          env={'PATH': '/usr/bin:/bin', 'TMPDIR': r, 'HOME': r,
                               'PYTHONDONTWRITEBYTECODE': '1'})
    out = done.stdout.decode('utf-8', 'replace')
    print('   '+('deny had NO effect (still readable)' if 'SECRET' in out
                 else 'deny took effect -> -D substitution works' if done.returncode != 0
                 else 'inconclusive: '+(done.stderr.decode('utf-8','replace')[:200])))
finally:
    shutil.rmtree(d, ignore_errors=True)

print('\nrequired read areas: '+(', '.join(required) if required else '(none identified)'))
