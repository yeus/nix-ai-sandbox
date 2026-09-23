#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${1:?runtime directory is required}"
version="${2:?tunnel-client version is required}"
tunnel_id="${3:?tunnel ID is required}"
winx_version="${4:?Winx version is required}"
: "${CONTROL_PLANE_API_KEY:?CONTROL_PLANE_API_KEY is required}"

case "$(uname -m)" in
  x86_64) platform=linux-amd64 ;;
  aarch64|arm64) platform=linux-arm64 ;;
  *) echo "Unsupported tunnel-client architecture: $(uname -m)" >&2; exit 1 ;;
esac

client="/sandbox-home/.local/share/ai-sandbox/mcp/tunnel-client/$version-$platform/tunnel-client"
tunnel_dir="$runtime_dir/tunnel"
state_dir="$tunnel_dir/state"
profile_dir="$tunnel_dir/profiles"
result="$tunnel_dir/connect.$$.json"
status_file="$tunnel_dir/status.$$.json"
metadata="$tunnel_dir/metadata.json"
cleanup() {
  rm -f -- "$result" "$status_file"
}
trap cleanup EXIT

mkdir -p "$state_dir" "$profile_dir"
chmod 0700 "$tunnel_dir" "$state_dir" "$profile_dir"
export TUNNEL_CLIENT_STATE_DIR="$state_dir"

if ! "$client" runtimes connect --json \
  --alias workspace \
  --profile workspace \
  --profile-dir "$profile_dir" \
  --tunnel-id "$tunnel_id" \
  --runtime-api-key env:CONTROL_PLANE_API_KEY \
  --mcp-command "/usr/local/bin/ai-sandbox-mcp-launch $winx_version" \
  >"$result"; then
  jq '{tunnel_id, process_running, healthy, ready, error, launch_diagnostics}' \
    "$result" >&2 2>/dev/null || true
  exit 1
fi

ready=0
for ((attempt = 1; attempt <= 120; attempt++)); do
  # Readiness only needs local runtime health. Hiding the key prevents status
  # from repeating the remote tunnel lookup performed by connect.
  if env -u CONTROL_PLANE_API_KEY \
    "$client" runtimes status workspace --json >"$status_file" 2>/dev/null &&
    jq -e '.process_running and .healthy and .ready' "$status_file" >/dev/null; then
    ready=1
    break
  fi
  if ((attempt % 20 == 0)); then
    echo "Still waiting for Secure MCP Tunnel readiness..." >&2
  fi
  sleep 0.5
done

source_file="$status_file"
jq -e . "$status_file" >/dev/null 2>&1 || source_file="$result"
if ! jq -e . "$source_file" >/dev/null 2>&1; then
  echo "Secure MCP Tunnel produced no runtime status." >&2
  exit 1
fi
jq \
  --arg version "$version" \
  --arg transport "OpenAI Secure MCP Tunnel" \
  '{
    tunnel_id: (.tunnel_id // .tunnel.id),
    process_running,
    healthy,
    ready,
    health_url,
    ui_url
  } + {version: $version, transport: $transport}' \
  "$source_file" >"$metadata.tmp.$$"
mv "$metadata.tmp.$$" "$metadata"

if [[ "$ready" -ne 1 ]]; then
  jq '{process_running, healthy, ready, error, launch_diagnostics}' \
    "$source_file" >&2 2>/dev/null || true
  echo "Secure MCP Tunnel did not become ready." >&2
  echo "Inspect it with 'ais mcp --status' or stop it with 'ais mcp --stop'." >&2
  exit 1
fi
