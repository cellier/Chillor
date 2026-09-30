"""Decide whether the problem is WHICH paths are allowed, or filtered read rules at all.

Unrestricted (allow file-read*) works; every whitelist so far fails, even one
containing all of /private/var/folders. Phase 1 settles the question with
(subpath "/"), which matches everything a filter can match:

  * if (subpath "/") FAILS  -> filtered file-read rules are the problem, not paths
  * if (subpath "/") PASSES -> a specific top level is missing, and phase 2
                               enumerates exactly which by elimination

Run: Resources/AgentPython/bin/python3 Tests/sandbox_root.py
"""
import pathlib, shutil, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'Resources/AgentTools'))
import sandbox

PY_EXE = sys.executable
HOME = sandbox.python_home(PY_EXE)
PROGRAM = "from PIL import Image\nImage.new('RGB',(4,4)).save('p.png')\nprint('INSIDE-OK')\n"

COMMON = ('(allow process-fork)\n(allow process-exec*)\n(allow file-map-executable)\n'
          '(allow file-read-metadata)\n(allow sysctl-read)\n(allow mach-lookup)\n'
          '(allow ipc-posix-shm*)\n(allow signal)\n')


def try_profile(read_rule, label):
    directory = tempfile.mkdtemp(prefix='sbx-rt-')
    run_dir = str(pathlib.Path(directory).resolve())
    try:
        text = (f'(version 1)\n(deny default)\n(deny network*)\n{COMMON}'
                f'{read_rule.replace("__RUN__", run_dir)}\n'
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
        if not good:
            err = done.stderr.decode('utf-8', 'replace').strip()
            for line in err.splitlines()[:6]:
                print('        | '+line)
        return good
    finally:
        shutil.rmtree(directory, ignore_errors=True)


print('interpreter : '+PY_EXE+'\n')
print('phase 1 — is it the paths, or filtered rules themselves?')
try_profile('(allow file-read*)', 'unrestricted (control)')
root_ok = try_profile('(allow file-read* (subpath "/"))', '(subpath "/")')
try_profile('(allow file-read* (subpath "/") (subpath "__RUN__"))', '(subpath "/") + run dir')
try_profile('(allow file-read*)\n(allow file-read* (subpath "/usr"))',
            'unrestricted + a redundant filtered rule')

if not root_ok:
    print('\n(subpath "/") does not work, so no path list will ever work.')
    print('The filter itself is being rejected or shadowed — send this output.')
    sys.exit(0)

print('\nphase 2 — which top level is actually required')
tops = sorted(p.name for p in pathlib.Path('/').iterdir() if not p.name.startswith('.'))
allow_all = ' '.join('(subpath "/%s")' % name for name in tops)
if not try_profile(f'(allow file-read* (literal "/") {allow_all} (subpath "__RUN__"))',
                   'every top-level entry listed individually'):
    print('\nlisting every top level is not equivalent to (subpath "/"):')
    print('the root literal or a hidden entry matters — send this output.')
    sys.exit(0)

required = []
for name in tops:
    rest = ' '.join('(subpath "/%s")' % other for other in tops if other != name)
    if not try_profile(f'(allow file-read* (literal "/") {rest} (subpath "__RUN__"))',
                       'without /'+name):
        required.append('/'+name)

print('\nrequired top levels: '+(', '.join(required) if required else '(none)'))
print('the shipped profile must contain these, plus the run directory.')
