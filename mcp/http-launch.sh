#!/usr/bin/env bash
set -euo pipefail

version="${1:?Winx version is required}"
bind="${2:?HTTP bind address is required}"
token_file="${3:?token file is required}"
allowed_host="${4:-}"

[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Invalid Winx version: $version" >&2
  exit 1
}
binary="/sandbox-home/.local/share/ai-sandbox/mcp/winx/$version/winx-code-agent"
[[ -x "$binary" ]] || { echo "Winx is not installed." >&2; exit 1; }

cd /workspace
runtime_dir="${AI_SANDBOX_MCP_RUNTIME_DIR:-/sandbox-home}"
mkdir -p "$runtime_dir/runtime"
chmod 0700 "$runtime_dir/runtime"
export WINX_USAGE_LOG="$runtime_dir/runtime/usage.jsonl"
export WINX_USAGE_LOG_ROTATION=never
export WINX_ALLOW_PATHS=/sandbox-home/.codex/AGENTS.md
export WINX_SERVER_INSTRUCTIONS="After Initialize, use ReadFiles to read /sandbox-home/.codex/AGENTS.md and /workspace/AGENTS.md if present, then any nested AGENTS.md relevant to the files you work on. Follow those instructions when using this sandbox."
unset CONTROL_PLANE_API_KEY WINX_HTTP_TOKEN

args=(
  serve --http
  --bind "$bind"
  --token-file "$token_file"
  --session-affinity workspace
)
if [[ "$bind" != 127.0.0.1:* && "$bind" != "[::1]:"* ]]; then
  args+=(--allow-non-loopback)
fi
[[ -z "$allowed_host" ]] || args+=(--allowed-host "$allowed_host")

exec env AI_SANDBOX_MODE=mcp-exec \
  /usr/local/bin/container-entrypoint.sh "$binary" "${args[@]}"
