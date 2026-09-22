#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${1:?runtime directory is required}"
pid_file="$runtime_dir/runtime/pid"
[[ -s "$pid_file" ]] || { echo stopped; exit 0; }
pid="$(<"$pid_file")"
[[ "$pid" =~ ^[0-9]+$ ]] || { echo stale; exit 0; }
kill -0 "$pid" 2>/dev/null || { echo stale; exit 0; }

cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
environ="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null || true)"
if [[ "$cmdline" != *gpt-repo-mcp*'/dist/server.js'* ]] ||
  [[ "$environ" != *"GPT_REPO_CONFIG=$runtime_dir/config.json"* ]]; then
  echo stale
  exit 0
fi
echo running
