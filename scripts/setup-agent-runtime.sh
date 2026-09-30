#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
[[ "$(uname -m)" == arm64 ]] || { print -u2 'This development runtime supports Apple Silicon.'; exit 1; }
# A relocatable CPython distribution; no dependency on /usr/bin/python3 (3.9).
# Override when preparing a distribution on another build host.
chillor_python_source="${CHILLOR_PYTHON_SOURCE:-}"
if [[ ! -x Resources/AgentPython/bin/python3 ]]; then
  [[ -x "$chillor_python_source/bin/python3" ]] || { print -u2 'Set CHILLOR_PYTHON_SOURCE to a relocatable Python 3.12 distribution.'; exit 1; }
  "$chillor_python_source/bin/python3" -c 'import sys; assert sys.version_info[:2] == (3,12), "Python 3.12 required"'
  "$chillor_python_source/bin/python3" - "$chillor_python_source" <<'PY'
import pathlib,shutil,sys
shutil.copytree(sys.argv[1], 'Resources/AgentPython', symlinks=True,
                ignore=shutil.ignore_patterns('site-packages','__pycache__','include','pkgconfig'), dirs_exist_ok=True)
PY
fi
Resources/AgentPython/bin/python3 -m ensurepip
Resources/AgentPython/bin/python3 -m pip install --disable-pip-version-check -r Resources/AgentTools/agent-requirements.lock
Resources/AgentPython/bin/python3 -c 'from agents import Agent, Runner, SQLiteSession; from agents.mcp import MCPServerStdio; import docx, openpyxl, pptx, PIL; print("Local SDK runtime ready")'
