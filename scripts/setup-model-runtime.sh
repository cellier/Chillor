#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
[[ "$(uname -m)" == arm64 ]] || { print -u2 'Apple Silicon is required.'; exit 1; }
if [[ -x Resources/ModelRuntime/ollama ]]; then
  print 'Model runtime already present.'
  exit 0
fi
chillor_runtime_source="${CHILLOR_MODEL_RUNTIME_SOURCE:-}"
[[ -n "$chillor_runtime_source" && -x "$chillor_runtime_source/ollama" ]] || {
  print -u2 'Set CHILLOR_MODEL_RUNTIME_SOURCE to a trusted ARM64 Ollama runtime directory (executable, libraries and licenses).'
  exit 1
}
mkdir -p Resources/ModelRuntime
ditto "$chillor_runtime_source" Resources/ModelRuntime
print 'Model runtime copied. Model weights are downloaded separately during setup.'
