#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${1:?runtime directory is required}"
version="${2:?Winx version is required}"
bind_host="${3:?bind host is required}"
port="${4:?port is required}"
allowed_host="${5:-}"
http_dir="$runtime_dir/http"
metadata="$http_dir/metadata.json"
pid_file="$http_dir/server.pid"
log_file="$http_dir/server.log"
token_file="$http_dir/token.$$.tmp"

mkdir -p "$http_dir"
chmod 0700 "$http_dir"
umask 077
IFS= read -r token
[[ ${#token} -ge 32 ]] || {
  echo "MCP HTTP bearer token must contain at least 32 bytes." >&2
  exit 1
}
printf '%s\n' "$token" >"$token_file"
chmod 0600 "$token_file"
cleanup() { rm -f -- "$token_file"; }
trap cleanup EXIT

if [[ -f "$pid_file" ]] && kill -0 "$(<"$pid_file")" 2>/dev/null; then
  echo "MCP HTTP server is already running." >&2
  exit 0
fi

: >"$log_file"
nohup env "AI_SANDBOX_MCP_RUNTIME_DIR=$runtime_dir" \
  /usr/local/bin/ai-sandbox-mcp-http-launch \
  "$version" "$bind_host:$port" "$token_file" "$allowed_host" \
  >"$log_file" 2>&1 </dev/null &
pid=$!
printf '%s\n' "$pid" >"$pid_file"

ready=0
for ((attempt = 1; attempt <= 100; attempt++)); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "MCP HTTP server exited during startup." >&2
    tail -40 "$log_file" >&2 || true
    exit 1
  fi
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
[[ "$ready" -eq 1 ]] || {
  echo "MCP HTTP server did not become ready." >&2
  kill "$pid" 2>/dev/null || true
  exit 1
}

# Winx eagerly loads --token-file before opening the listener. Remove the
# transient copy before any caller can use Bash to inspect the container.
rm -f -- "$token_file"
trap - EXIT
jq -n \
  --arg bind "$bind_host" \
  --argjson port "$port" \
  --argjson pid "$pid" \
  --arg allowed_host "$allowed_host" \
  '{
    configured: true,
    process_running: true,
    bind: $bind,
    port: $port,
    path: "/mcp",
    auth: "bearer",
    pid: $pid,
    allowed_host: ($allowed_host | if length > 0 then . else null end)
  }' >"$metadata.tmp.$$"
mv "$metadata.tmp.$$" "$metadata"
