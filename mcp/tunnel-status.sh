#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${1:?runtime directory is required}"
version="${2:?tunnel-client version is required}"
tunnel_dir="$runtime_dir/tunnel"
metadata="$tunnel_dir/metadata.json"

if [[ ! -f "$metadata" ]]; then
  jq -n '{configured: false, process_running: false, healthy: false, ready: false}'
  exit 0
fi

case "$(uname -m)" in
  x86_64) platform=linux-amd64 ;;
  aarch64|arm64) platform=linux-arm64 ;;
  *) platform=unsupported ;;
esac

client="/sandbox-home/.local/share/ai-sandbox/mcp/tunnel-client/$version-$platform/tunnel-client"
status_file="$tunnel_dir/status.$$.json"
cleanup() {
  rm -f -- "$status_file"
}
trap cleanup EXIT
export TUNNEL_CLIENT_STATE_DIR="$tunnel_dir/state"

if [[ -x "$client" ]] &&
  "$client" runtimes status workspace --json >"$status_file" 2>/dev/null; then
  jq -s \
    '.[0] + {
      configured: true,
      process_running: (.[1].process_running // false),
      healthy: (.[1].healthy // false),
      ready: (.[1].ready // false),
      health_url: (.[1].health_url // .[0].health_url // null),
      ui_url: (.[1].ui_url // .[0].ui_url // null)
    }' "$metadata" "$status_file"
else
  jq '. + {configured: true, process_running: false, healthy: false, ready: false}' \
    "$metadata"
fi
