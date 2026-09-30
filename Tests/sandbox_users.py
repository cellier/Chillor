"""How much of /Users does the interpreter actually need?

Allowing all of /Users works; allowing only the interpreter directory does not.
So something under /Users but outside AgentPython is required. This adds the
candidates back one at a time, narrowest first, and prints what the interpreter
says when it is refused.

Run: Resources/AgentPython/bin/python3 Tests/sandbox_users.py
"""
import pathlib, shutil, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'Resources/AgentTools'))
import sandbox

PY_EXE = sys.executable
EXE = pathlib.Path(PY_EXE)
PROGRAM = "from PIL import Image\nImage.new('RGB',(4,4)).save('p.png')\nprint('INSIDE-OK')\n"

COMMON = ('(allow process-fork)\n(allow process-exec*)\n(allow file-map-executable)\n'
          '(allow file-read-metadata)\n(allow sysctl-read)\n(allow mach-lookup)\n'
          '(allow ipc-posix-shm*)\n(allow signal)\n')

TOPS = sorted(p.name for p in pathlib.Path('/').iterdir()
              if not p.name.startswith('.') and p.name != 'Users')


def attempt(label, extra):
    directory = tempfile.mkdtemp(prefix='sbx-us-')
    run_dir = str(pathlib.Path(directory).resolve())
    try:
        reads = ' '.join('(subpath "/%s")' % n for n in TOPS)
        reads += ' ' + ' '.join('(subpath "%s")' % p for p in extra)
        text = (f'(version 1)\n(deny default)\n(deny network*)\n{COMMON}'
                f'(allow file-read* (literal "/") {reads} (subpath "{run_dir}"))\n'
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
            for line in err.splitlines()[:14]:
                print('        | '+line)
        return good
    finally:
        shutil.rmtree(directory, ignore_errors=True)


home = EXE.parent.parent                      # .../Resources/AgentPython
resolved = EXE.resolve()
print('executable          : '+str(EXE))
print('executable resolved : '+str(resolved)+('   (SYMLINK)' if resolved != EXE else ''))
print('interpreter dir     : '+str(home))
print('sys.prefix          : '+sys.prefix)
print('sys.base_prefix     : '+sys.base_prefix)
import sysconfig
for key in ('stdlib', 'platstdlib', 'purelib'):
    try:
        print('%-20s: %s' % (key, sysconfig.get_path(key)))
    except Exception:
        pass
print('\nlib/ entries:')
for entry in sorted((home/'lib').iterdir())[:12] if (home/'lib').is_dir() else []:
    target = ' -> '+str(entry.resolve()) if entry.is_symlink() else ''
    print('   '+entry.name+target)

print('\nadding candidates back, narrowest first')
attempt('nothing under /Users', [])
attempt('interpreter dir only', [str(home)])
attempt('+ its parent (Resources)', [str(home.parent)])
attempt('+ the project folder', [str(home.parent.parent)])
attempt('+ the home directory', [str(EXE.parents[len(EXE.parts)-4] if False else pathlib.Path.home())])
attempt('all of /Users', ['/Users'])
