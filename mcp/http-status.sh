#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${1:?runtime directory is required}"
http_dir="$runtime_dir/http"
metadata="$http_dir/metadata.json"
pid_file="$http_dir/server.pid"

if [[ ! -f "$metadata" ]]; then
  jq -n '{configured: false, process_running: false}'
  exit 0
fi
running=false
if [[ -f "$pid_file" ]] && kill -0 "$(<"$pid_file")" 2>/dev/null; then
  running=true
fi
jq --argjson running "$running" \
  '. + {configured: true, process_running: $running}' "$metadata"
