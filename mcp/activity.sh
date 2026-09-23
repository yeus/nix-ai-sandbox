#!/usr/bin/env bash
set -euo pipefail

log_file="${1:?Winx usage log is required}"
coproc ACTIVITY_TAIL { tail -n 0 -F "$log_file"; }
tail_pid="$ACTIVITY_TAIL_PID"
cleanup() {
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true
}
trap cleanup EXIT

while IFS= read -r line <&"${ACTIVITY_TAIL[0]}"; do
  jq -r \
    'select(.fields.event == "tool_call") |
     [.timestamp, .fields.tool, .fields.action, .fields.outcome] |
     map(. // "") | join(" ")' <<<"$line"
done
