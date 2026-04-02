#!/usr/bin/env bash
set -euo pipefail

if [[ -x /usr/local/bin/ai-sandbox-vscode-update ]]; then
  /usr/local/bin/ai-sandbox-vscode-update --if-missing
fi

code_bin="${HOME}/.local/opt/vscode/bin/code"
if [[ ! -x "$code_bin" ]]; then
  echo "AI_SANDBOX: user-space VS Code binary not found at ${code_bin}" >&2
  echo "Run: ai-sandbox-vscode-update --force" >&2
  exit 127
fi

exec "$code_bin" "$@"
