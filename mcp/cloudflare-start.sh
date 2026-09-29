#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${1:?runtime directory is required}"
version="${2:?cloudflared version is required}"
mode="${3:?publisher mode is required}"
origin_url="${4:?origin URL is required}"
public_url="${5:-}"

client="/sandbox-home/.local/share/ai-sandbox/mcp/cloudflared/$version/cloudflared"
[[ -x "$client" ]] || { echo "cloudflared is not installed." >&2; exit 1; }
publish_dir="$runtime_dir/publish"
metadata="$publish_dir/metadata.json"
pid_file="$publish_dir/cloudflared.pid"
log_file="$publish_dir/cloudflared.log"
token_file="$publish_dir/token.$$.tmp"
mkdir -p "$publish_dir"
chmod 0700 "$publish_dir"

if [[ -f "$pid_file" ]] && kill -0 "$(<"$pid_file")" 2>/dev/null; then
  echo "Cloudflare publisher is already running." >&2
  exit 0
fi

: >"$log_file"
case "$mode" in
  quick)
    nohup "$client" tunnel --no-autoupdate --loglevel info \
      --url "$origin_url" >"$log_file" 2>&1 </dev/null &
    ;;
  named)
    [[ "$public_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || {
      echo "Named Cloudflare publishing requires an HTTPS base URL." >&2
      exit 1
    }
    umask 077
    IFS= read -r token
    [[ -n "$token" ]] || {
      echo "Cloudflare tunnel token is required." >&2
      exit 1
    }
    printf '%s\n' "$token" >"$token_file"
    chmod 0600 "$token_file"
    nohup "$client" tunnel --no-autoupdate --loglevel info run \
      --token-file "$token_file" >"$log_file" 2>&1 </dev/null &
    ;;
  *)
    echo "Unknown Cloudflare publisher mode: $mode" >&2
    exit 1
    ;;
esac
pid=$!
printf '%s\n' "$pid" >"$pid_file"

ready=0
if [[ "$mode" == quick ]]; then
  for ((attempt = 1; attempt <= 120; attempt++)); do
    kill -0 "$pid" 2>/dev/null || break
    public_url="$(rg -o 'https://[a-z0-9-]+\.trycloudflare\.com' "$log_file" | head -1 || true)"
    if [[ -n "$public_url" ]]; then
      ready=1
      break
    fi
    sleep 0.25
  done
else
  for ((attempt = 1; attempt <= 80; attempt++)); do
    kill -0 "$pid" 2>/dev/null || break
    if rg -q 'Registered tunnel connection|Connection .* registered' "$log_file"; then
      ready=1
      break
    fi
    sleep 0.25
  done
fi

rm -f -- "$token_file"
if [[ "$ready" -ne 1 ]]; then
  echo "Cloudflare tunnel did not become ready." >&2
  tail -40 "$log_file" >&2 || true
  kill "$pid" 2>/dev/null || true
  exit 1
fi

jq -n \
  --arg mode "$mode" \
  --arg url "${public_url%/}" \
  --arg version "$version" \
  --argjson pid "$pid" \
  '{
    configured: true,
    provider: "cloudflare",
    mode: $mode,
    process_running: true,
    public_url: $url,
    version: $version,
    pid: $pid
  }' >"$metadata.tmp.$$"
mv "$metadata.tmp.$$" "$metadata"
