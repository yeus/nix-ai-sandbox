#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${1:?runtime directory is required}"
pid_file="$runtime_dir/runtime/pid"
[[ -s "$pid_file" ]] || exit 0
pid="$(<"$pid_file")"
[[ "$pid" =~ ^[0-9]+$ ]] || { rm -f "$pid_file"; exit 0; }

state="$(/usr/local/bin/ai-sandbox-mcp-status "$runtime_dir")"
if [[ "$state" == running ]]; then
  kill "$pid"
  for _ in {1..40}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
fi
rm -f "$pid_file"
