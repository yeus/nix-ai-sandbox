#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${1:?runtime directory is required}"
commit="${2:?implementation commit is required}"
port="${3:?port is required}"
install_dir="/sandbox-home/.local/share/ai-sandbox/mcp/gpt-repo-mcp/$commit"
config="$runtime_dir/config.json"
pid_file="$runtime_dir/runtime/pid"
log_file="$runtime_dir/runtime/server.log"

unset AI_SANDBOX_HOST_MOUNT_ROOT

mkdir -p "$runtime_dir/runtime" "$runtime_dir/upstream-runtime"
rm -f "$pid_file"

GPT_REPO_CONFIG="$config" \
GPT_REPO_HOST=127.0.0.1 \
PORT="$port" \
nohup node "$install_dir/dist/server.js" \
  </dev/null >"$log_file" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$pid_file"

sleep 0.1
if ! kill -0 "$pid" 2>/dev/null; then
  echo "MCP server exited during startup." >&2
  sed -n '1,120p' "$log_file" >&2 || true
  rm -f "$pid_file"
  exit 1
fi
