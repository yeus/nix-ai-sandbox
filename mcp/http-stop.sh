#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${1:?runtime directory is required}"
http_dir="$runtime_dir/http"
pid_file="$http_dir/server.pid"
[[ -f "$pid_file" ]] || exit 0
pid="$(<"$pid_file")"
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  for _ in {1..30}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$pid_file"
