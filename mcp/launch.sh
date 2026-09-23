#!/usr/bin/env bash
set -euo pipefail

version="${1:?Winx version is required}"
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Invalid Winx version: $version" >&2
  exit 1
}
binary="/sandbox-home/.local/share/ai-sandbox/mcp/winx/$version/winx-code-agent"
[[ -x "$binary" ]] || { echo "Winx is not installed." >&2; exit 1; }

cd /workspace
mkdir -p /sandbox-home/runtime
chmod 0700 /sandbox-home/runtime
export WINX_USAGE_LOG=/sandbox-home/runtime/usage.jsonl
export WINX_USAGE_LOG_ROTATION=never
unset CONTROL_PLANE_API_KEY
exec "$binary" serve
