"""Remove reproducible/obsolete bundle files, never trim model backends or SDKs."""
import hashlib
import pathlib
import shutil
import sys

bundle = pathlib.Path(sys.argv[1]).resolve()
resources = bundle / 'Contents/Resources'
assert (resources / 'AgentPython/bin/python3').is_file()
assert (resources / 'runtime/ollama').is_file()

# All app consumers now use the bundled Python 3.12 runtime.
# This directory was the old system-Python 3.9 compatibility environment.
for name in ('AgentRuntime', 'AgentTools/packages'):
    path = resources / name
    if path.exists():
        shutil.rmtree(path)
old_icon = resources / 'AppIcon.icns'
if old_icon.exists():
    old_icon.unlink()

# Remove bytecode only if its Python source is present; preserve sourceless modules.
for path in resources.rglob('*.pyc'):
    if path.parent.name == '__pycache__':
        source = path.parent.parent / (path.name.split('.')[0] + '.py')
        if source.is_file():
            path.unlink()

bin_dir = resources / 'AgentPython/bin'
canonical = bin_dir / 'python3'
digest = hashlib.sha256(canonical.read_bytes()).digest()
for name in ('python', 'python3.12'):
    path = bin_dir / name
    if path.is_file() and not path.is_symlink() and hashlib.sha256(path.read_bytes()).digest() == digest:
        path.unlink()
        path.symlink_to('python3')
