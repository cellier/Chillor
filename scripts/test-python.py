#!/usr/bin/env python3
"""Run both unittest modules and standalone checks in separate processes."""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
failed = []
for test in sorted((root / 'Tests').glob('*test.py')):
    print(f'\n=== {test.name} ===', flush=True)
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    # Offline checks must never inherit real inference credentials.
    environment.pop('CHILLOR_API_KEY', None)
    try:
        result = subprocess.run([sys.executable, '-B', str(test)], cwd=root,
                                env=environment, timeout=300)
        if result.returncode:
            failed.append(test.name)
    except subprocess.TimeoutExpired:
        failed.append(test.name + ' (timeout)')
print('\nFailed: ' + ', '.join(failed) if failed else '\nAll Python test scripts passed.')
sys.exit(bool(failed))
