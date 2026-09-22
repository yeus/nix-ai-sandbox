#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${1:?runtime directory is required}"
version="${2:?tunnel-client version is required}"
tunnel_dir="$runtime_dir/tunnel"
[[ -f "$tunnel_dir/metadata.json" ]] || exit 0

case "$(uname -m)" in
  x86_64) platform=linux-amd64 ;;
  aarch64|arm64) platform=linux-arm64 ;;
  *) exit 0 ;;
esac

client="/sandbox-home/.local/share/ai-sandbox/mcp/tunnel-client/$version-$platform/tunnel-client"
export TUNNEL_CLIENT_STATE_DIR="$tunnel_dir/state"
if [[ -x "$client" ]]; then
  "$client" runtimes stop workspace --json >/dev/null 2>&1 || true
fi
