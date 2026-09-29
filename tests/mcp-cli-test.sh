#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ai_sandbox="$repo_root/ai-sandbox/ai-sandbox"
test_root="$(mktemp -d)"
foreground_pid=""
activity_pid=""
cleanup() {
  [[ -z "$foreground_pid" ]] || kill "$foreground_pid" 2>/dev/null || true
  [[ -z "$activity_pid" ]] || kill "$activity_pid" 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup EXIT
workspace="$test_root/workspace"
mkdir -p "$workspace" "$test_root/bin" "$test_root/secrets"
git -C "$workspace" init -q

export AI_SANDBOX_STATE_DIR="$test_root/state"
export AI_SANDBOX_HOME_STORAGE="$test_root/home"
export AI_SANDBOX_NIX_STORAGE="$test_root/nix"
export AI_SANDBOX_SECRETS_STORAGE="$test_root/secret-storage"
export AI_SANDBOX_ANDROID_STATE_DIR="$test_root/android"
export AI_SANDBOX_TMP_ROOT="$test_root/host-tmp"
export AI_SANDBOX_NETWORK_MODE=bridge
export AI_SANDBOX_AUTO_RECONNECT=0
export AI_SANDBOX_TEST_ROOT="$test_root"
export PATH="$test_root/bin:/usr/bin:/bin"
mkdir -p "$AI_SANDBOX_HOME_STORAGE/.codex"
printf 'Synthetic sandbox instructions.\n' \
  >"$AI_SANDBOX_HOME_STORAGE/.codex/AGENTS.md"
cat >"$test_root/bin/secret-tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  lookup) cat "$AI_SANDBOX_TEST_ROOT/secrets/$5" ;;
  store) cat >"$AI_SANDBOX_TEST_ROOT/secrets/$6" ;;
esac
EOF

cat >"$test_root/bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'podman' >>"$AI_SANDBOX_TEST_ROOT/commands.log"
printf ' <%s>' "$@" >>"$AI_SANDBOX_TEST_ROOT/commands.log"
printf '\n' >>"$AI_SANDBOX_TEST_ROOT/commands.log"

state="$AI_SANDBOX_TEST_ROOT/container-running"
runtime=""
for arg in "$@"; do
  if [[ "$arg" =~ ai-sandbox-[^-]+-mcp-([a-f0-9]{12}) ]]; then
    runtime="$AI_SANDBOX_HOME_STORAGE/.ai-sandbox/mcp-winx/${BASH_REMATCH[1]}"
    break
  fi
done
[[ -n "$runtime" ]] || runtime="$(find "$AI_SANDBOX_HOME_STORAGE/.ai-sandbox/mcp-winx" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)"
case "${1:-}" in
  image) exit 0 ;;
  run)
    touch "$state"
    if [[ "$*" == *'--network host'* ]]; then
      echo host >"$AI_SANDBOX_TEST_ROOT/container-network"
    else
      echo bridge >"$AI_SANDBOX_TEST_ROOT/container-network"
    fi
    echo synthetic-container-id
    exit 0
    ;;
  start) touch "$state"; exit 0 ;;
  stop) rm -f "$state"; exit 0 ;;
  inspect)
    [[ "$*" == *-mcp-* && -f "$state" ]] || exit 1
    case "$*" in
      *State.Status*) echo running ;;
      *State.Running*) echo true ;;
      *HostConfig.NetworkMode*) cat "$AI_SANDBOX_TEST_ROOT/container-network" ;;
      *Config.Env*) echo "AI_SANDBOX_NETWORK_MODE=$(cat "$AI_SANDBOX_TEST_ROOT/container-network")" ;;
      *Id*) echo synthetic-container-id ;;
    esac
    exit 0
    ;;
  exec)
    case "$*" in
      *ai-sandbox-mcp-http-start*)
        cat >/dev/null
        mkdir -p "$runtime/http"
        bind=127.0.0.1
        [[ "$*" != *0.0.0.0* ]] || bind=0.0.0.0
        jq -n \
          --arg bind "$bind" \
          '{configured: true, process_running: true, bind: $bind, port: 18081, path: "/mcp", auth: "bearer"}' \
          >"$runtime/http/metadata.json"
        touch "$runtime/http/running"
        ;;
      *ai-sandbox-mcp-http-status*)
        if [[ -f "$runtime/http/running" ]]; then
          cat "$runtime/http/metadata.json"
        elif [[ -f "$runtime/http/metadata.json" ]]; then
          jq '. + {process_running: false}' "$runtime/http/metadata.json"
        else
          echo '{"configured":false,"process_running":false}'
        fi
        ;;
      *ai-sandbox-mcp-http-stop*) rm -f "$runtime/http/running" ;;
      *ai-sandbox-mcp-cloudflare-start*)
        mode=quick
        [[ "$*" != *" named "* ]] || mode=named
        [[ "$mode" != named ]] || cat >/dev/null
        mkdir -p "$runtime/publish"
        if [[ "$mode" == named ]]; then
          public_url="${@: -1}"
        else
          public_url=https://synthetic.trycloudflare.com
        fi
        jq -n \
          --arg mode "$mode" \
          --arg public_url "$public_url" \
          '{configured: true, provider: "cloudflare", mode: $mode, process_running: true, public_url: $public_url, version: "2026.9.3"}' \
          >"$runtime/publish/metadata.json"
        touch "$runtime/publish/running"
        ;;
      *ai-sandbox-mcp-cloudflare-status*)
        if [[ -f "$runtime/publish/running" ]]; then
          cat "$runtime/publish/metadata.json"
        elif [[ -f "$runtime/publish/metadata.json" ]]; then
          jq '. + {process_running: false}' "$runtime/publish/metadata.json"
        else
          echo '{"configured":false,"process_running":false}'
        fi
        ;;
      *ai-sandbox-mcp-cloudflare-stop*) rm -f "$runtime/publish/running" ;;
      *ai-sandbox-mcp-tunnel-start*)
        mkdir -p "$runtime/tunnel"
        jq -n '{configured: true, tunnel_id: "tunnel_0123456789abcdef0123456789abcdef", version: "v0.0.14", process_running: true, healthy: true, ready: true}' \
          >"$runtime/tunnel/metadata.json"
        touch "$runtime/tunnel/running"
        ;;
      *ai-sandbox-mcp-tunnel-status*)
        if [[ -f "$runtime/tunnel/running" ]]; then
          cat "$runtime/tunnel/metadata.json"
        else
          jq '. + {process_running: false, healthy: false, ready: false}' \
            "$runtime/tunnel/metadata.json"
        fi
        ;;
      *ai-sandbox-mcp-tunnel-stop*) rm -f "$runtime/tunnel/running" ;;
      *'winx-code-agent list'*)
        if [[ ! -f "$AI_SANDBOX_TEST_ROOT/winx-ready" ]]; then
          touch "$AI_SANDBOX_TEST_ROOT/list-before-ready"
          exit 1
        fi
        echo '[{"thread_id":"synthetic-thread-id"}]'
        ;;
      *'winx-code-agent attach'*) echo synthetic-shell-output ;;
    esac
    exit 0
    ;;
esac
EOF
chmod +x "$test_root/bin/secret-tool" "$test_root/bin/podman"

if "$ai_sandbox" mcp "$workspace" --tunnel \
  >"$test_root/missing.out" 2>"$test_root/missing.err"; then
  echo "MCP started without tunnel credentials" >&2
  exit 1
fi
rg -q 'settings/organization/tunnels' "$test_root/missing.err"
rg -q 'settings/organization/api-keys' "$test_root/missing.err"
printf '%s' tunnel_0123456789abcdef0123456789abcdef \
  >"$test_root/secrets/tunnel-id"
printf '%s' sk-synthetic-test-value \
  >"$test_root/secrets/runtime-api-key"

mkdir -p "$test_root/secret-target"
ln -s "$test_root/secret-target" "$test_root/symlink-secrets"
if AI_SANDBOX_SECRETS_STORAGE="$test_root/symlink-secrets" \
  "$ai_sandbox" mcp "$workspace" --show-token \
  >"$test_root/symlink.out" 2>"$test_root/symlink.err"; then
  echo "MCP accepted a symlinked host secret store" >&2
  exit 1
fi
rg -q 'Refusing symlinked AI Sandbox secrets directory' \
  "$test_root/symlink.err"
workspace_hash="$(printf '%s' "$workspace" | sha256sum | cut -c1-12)"
secret_dir="$AI_SANDBOX_SECRETS_STORAGE/mcp/$workspace_hash"
mkdir -p "$secret_dir"
chmod 0700 "$AI_SANDBOX_SECRETS_STORAGE" \
  "$AI_SANDBOX_SECRETS_STORAGE/mcp" "$secret_dir"
http_token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
printf '%s\n' "$http_token" >"$secret_dir/bearer-token"
chmod 0600 "$secret_dir/bearer-token"

: >"$test_root/commands.log"
if ! "$ai_sandbox" mcp "$workspace" --local --port 18765 \
  >"$test_root/local.out" 2>"$test_root/local.err"; then
  cat "$test_root/local.err" >&2
  exit 1
fi
rg -q 'Transport: Streamable HTTP' "$test_root/local.out"
rg -q '^Connection: mcp1$' "$test_root/local.out"
rg -q 'Endpoint: http://127.0.0.1:18765/mcp' "$test_root/local.out"
rg -q 'Authentication: bearer token' "$test_root/local.out"
rg -F '<-p> <127.0.0.1:18765:18081>' "$test_root/commands.log" >/dev/null
rg -F '<--network> <private>' "$test_root/commands.log" >/dev/null
rg -F '</usr/local/bin/ai-sandbox-mcp-http-start>' "$test_root/commands.log" >/dev/null
if rg -q "$http_token" "$test_root/commands.log"; then
  echo "HTTP auth token leaked to command arguments" >&2
  exit 1
fi
if rg -F "$AI_SANDBOX_SECRETS_STORAGE" "$test_root/commands.log"; then
  echo "Host MCP secret storage was mounted or passed into the container" >&2
  exit 1
fi
"$ai_sandbox" mcp "$workspace" --show-key >"$test_root/token.out"
rg -qx "$http_token" "$test_root/token.out"
"$ai_sandbox" mcp "$workspace" --status --json >"$test_root/local-status.json"
jq -e '.connection == "mcp1" and .transport == "streamable-http" and .endpoint == "http://127.0.0.1:18765/mcp" and .auth == "bearer" and .health == "ok"' \
  "$test_root/local-status.json" >/dev/null
"$ai_sandbox" mcp "$workspace" --stop >"$test_root/local-stop.out"

# The bearer token and local port survive MCP container restarts.
"$ai_sandbox" mcp "$workspace" --local \
  >"$test_root/local-repeat.out" 2>"$test_root/local-repeat.err"
rg -q 'Endpoint: http://127.0.0.1:18765/mcp' "$test_root/local-repeat.out"
rg -q '^Connection: mcp1$' "$test_root/local-repeat.out"
"$ai_sandbox" mcp "$workspace" --show-token >"$test_root/token-repeat.out"
cmp "$test_root/token.out" "$test_root/token-repeat.out"
"$ai_sandbox" mcp "$workspace" --stop >"$test_root/local-repeat-stop.out"

# A second workspace gets independent credential and port state.
workspace_two="$test_root/workspace-two"
mkdir -p "$workspace_two"
git -C "$workspace_two" init -q
"$ai_sandbox" mcp "$workspace_two" --local \
  >"$test_root/local-two.out" 2>"$test_root/local-two.err"
rg -q '^Connection: mcp2$' "$test_root/local-two.out"
endpoint_two="$(sed -n 's/^Endpoint: //p' "$test_root/local-two.out")"
[[ "$endpoint_two" =~ ^http://127\.0\.0\.1:[0-9]+/mcp$ ]]
[[ "$endpoint_two" != "http://127.0.0.1:18765/mcp" ]]
"$ai_sandbox" mcp "$workspace_two" --show-token >"$test_root/token-two.out"
if cmp -s "$test_root/token.out" "$test_root/token-two.out"; then
  echo "Two workspaces shared one MCP API key" >&2
  exit 1
fi
"$ai_sandbox" mcp "$workspace_two" --stop >"$test_root/local-two-stop.out"

# Explicit names are persistent and unique across workspaces.
workspace_three="$test_root/workspace-three"
mkdir -p "$workspace_three"
git -C "$workspace_three" init -q
"$ai_sandbox" mcp "$workspace_three" --local --connection designbox \
  >"$test_root/local-three.out" 2>"$test_root/local-three.err"
rg -q '^Connection: designbox$' "$test_root/local-three.out"
"$ai_sandbox" mcp "$workspace_three" --stop >"$test_root/local-three-stop.out"
"$ai_sandbox" mcp "$workspace_three" --local \
  >"$test_root/local-three-repeat.out" 2>"$test_root/local-three-repeat.err"
rg -q '^Connection: designbox$' "$test_root/local-three-repeat.out"
"$ai_sandbox" mcp "$workspace_three" --stop >"$test_root/local-three-repeat-stop.out"

workspace_four="$test_root/workspace-four"
mkdir -p "$workspace_four"
git -C "$workspace_four" init -q
if "$ai_sandbox" mcp "$workspace_four" --local --connection designbox \
  >"$test_root/local-four.out" 2>"$test_root/local-four.err"; then
  echo "Duplicate MCP connection name was accepted" >&2
  exit 1
fi
rg -q "already assigned to another workspace" "$test_root/local-four.err"


: >"$test_root/commands.log"
"$ai_sandbox" mcp "$workspace" --publish cloudflare-quick \
  >"$test_root/quick.out" 2>"$test_root/quick.err"
rg -q 'Endpoint: https://synthetic.trycloudflare.com/mcp' "$test_root/quick.out"
rg -q 'Publisher: Cloudflare Quick Tunnel' "$test_root/quick.out"
rg -F '</usr/local/bin/ai-sandbox-mcp-cloudflare-start>' "$test_root/commands.log" >/dev/null
if rg -F '<-p>' "$test_root/commands.log"; then
  echo "Published MCP unexpectedly opened a host port" >&2
  exit 1
fi
"$ai_sandbox" mcp "$workspace" --stop >"$test_root/quick-stop.out"

printf '%s\n' synthetic-cloudflare-tunnel-token \
  >"$secret_dir/cloudflare-tunnel-token"
printf '%s\n' https://mcp.example.test \
  >"$secret_dir/cloudflare-public-url"
chmod 0600 "$secret_dir/cloudflare-tunnel-token" \
  "$secret_dir/cloudflare-public-url"
: >"$test_root/commands.log"
"$ai_sandbox" mcp "$workspace" --publish cloudflare \
  >"$test_root/publish.out" 2>"$test_root/publish.err"
rg -q 'Endpoint: https://mcp.example.test/mcp' "$test_root/publish.out"
rg -q 'Publisher: Cloudflare named tunnel' "$test_root/publish.out"
if rg -q 'synthetic-cloudflare-tunnel-token' "$test_root/commands.log"; then
  echo "Cloudflare tunnel token leaked to command arguments" >&2
  exit 1
fi
"$ai_sandbox" mcp "$workspace" --status --json >"$test_root/publish-status.json"
jq -e '.transport == "streamable-http" and .publisher == "cloudflare" and .endpoint == "https://mcp.example.test/mcp" and .auth == "bearer" and .health == "ok"' \
  "$test_root/publish-status.json" >/dev/null
"$ai_sandbox" mcp "$workspace" --stop >"$test_root/publish-stop.out"

if "$ai_sandbox" mcp "$workspace" --local --tunnel \
  >"$test_root/invalid.out" 2>"$test_root/invalid.err"; then
  echo "Multiple MCP transports were accepted" >&2
  exit 1
fi
rg -q 'mutually exclusive' "$test_root/invalid.err"

if "$ai_sandbox" mcp "$workspace" --local --network host \
  >"$test_root/invalid.out" 2>"$test_root/invalid.err"; then
  echo "HTTP MCP accepted host networking" >&2
  exit 1
fi
rg -q 'require isolated bridge/private networking' "$test_root/invalid.err"

"$ai_sandbox" mcp "$workspace" --tunnel --detach \
  >"$test_root/start.out" 2>"$test_root/start.err"
rg -q 'Implementation: winx-code-agent @ v0.2.351' "$test_root/start.out"
rg -q 'Transport: stdio' "$test_root/start.out"
rg -q 'Health: OK' "$test_root/start.out"
rg -q '<--network> <host>|<--privileged>' "$test_root/commands.log" && {
  echo "MCP container weakened its boundary" >&2
  exit 1
}
runtime="$(find "$AI_SANDBOX_HOME_STORAGE/.ai-sandbox/mcp-winx" -mindepth 1 -maxdepth 1 -type d | head -1)"
rg -F "<$runtime:/sandbox-home>" "$test_root/commands.log" >/dev/null
cmp "$AI_SANDBOX_HOME_STORAGE/.codex/AGENTS.md" \
  "$runtime/.codex/AGENTS.md"
rg -F "<$AI_SANDBOX_HOME_STORAGE/.codex/AGENTS.md:/sandbox-home/.codex/AGENTS.md:ro>" \
  "$test_root/commands.log" >/dev/null
if rg -F "<$AI_SANDBOX_HOME_STORAGE:/sandbox-home>" \
  "$test_root/commands.log"; then
  echo "MCP inherited the shared sandbox home" >&2
  exit 1
fi
rg -F '</usr/local/bin/ai-sandbox-mcp-install> <v0.2.351>' \
  "$test_root/commands.log" >/dev/null
rg -F '</usr/local/bin/ai-sandbox-mcp-tunnel-start> </sandbox-home>' \
  "$test_root/commands.log" >/dev/null
if rg -q 'sk-synthetic-test-value' "$test_root/commands.log"; then
  echo "Runtime key leaked to command arguments" >&2
  exit 1
fi

: >"$test_root/commands.log"
"$ai_sandbox" mcp "$workspace" --tunnel --detach \
  >"$test_root/repeat.out" 2>"$test_root/repeat.err"
rg -q 'already running' "$test_root/repeat.err"
if rg -q 'ai-sandbox-mcp-install|ai-sandbox-mcp-tunnel-start|<run> <-d>' \
  "$test_root/commands.log"; then
  echo "Repeated MCP start relaunched its runtime" >&2
  exit 1
fi

if "$ai_sandbox" mcp "$workspace" \
  --tunnel tunnel_ffffffffffffffffffffffffffffffff \
  --detach >"$test_root/change.out" 2>"$test_root/change.err"; then
  echo "Running MCP switched tunnel ID" >&2
  exit 1
fi
rg -q 'Stop it before changing tunnels' "$test_root/change.err"

"$ai_sandbox" mcp "$workspace" --status --json \
  >"$test_root/status.json"
jq -e '.implementation == "winx-code-agent" and .transport == "stdio" and .health == "ok" and .tunnel.ready' \
  "$test_root/status.json" >/dev/null

touch "$test_root/winx-ready"
"$ai_sandbox" mcp "$workspace" --sessions \
  >"$test_root/sessions.out"
rg -q synthetic-thread-id "$test_root/sessions.out"
"$ai_sandbox" mcp "$workspace" --attach synthetic-thread-id \
  >"$test_root/attach.out"
rg -q synthetic-shell-output "$test_root/attach.out"

if "$ai_sandbox" mcp "$workspace" --tunnel --read-only --detach \
  >"$test_root/change.out" 2>"$test_root/change.err"; then
  echo "Winx unexpectedly accepted read-only mode" >&2
  exit 1
fi
rg -q 'read-only and --ship are unavailable' "$test_root/change.err"

"$ai_sandbox" mcp "$workspace" --stop \
  >"$test_root/stop.out"
[[ ! -f "$test_root/container-running" ]]
"$ai_sandbox" mcp "$workspace" --status --json \
  >"$test_root/stopped.json"
jq -e '.health == "stopped" and (.tunnel.ready | not)' \
  "$test_root/stopped.json" >/dev/null

# A foreground run starts quiet and toggles Winx output from its own terminal.
rm -f "$test_root/winx-ready"
: >"$test_root/commands.log"
mkfifo "$test_root/foreground.keys"
script -q -f -c \
  "sh -c 'echo \$\$ >\"$test_root/foreground.pid\"; exec \"$ai_sandbox\" mcp \"$workspace\" --tunnel'" \
  "$test_root/foreground.out" \
  <"$test_root/foreground.keys" \
  >"$test_root/foreground.stdout" 2>&1 &
foreground_pid=$!
exec 9>"$test_root/foreground.keys"
for _ in {1..40}; do
  [[ -f "$test_root/container-running" ]] && \
    [[ -f "$runtime/tunnel/running" ]] && \
    rg -q 'Press v to show Winx output' \
      "$test_root/foreground.out" && break
  sleep 0.1
done
[[ -f "$runtime/tunnel/running" ]]
! rg -q synthetic-shell-output "$test_root/foreground.out"
printf '%s\n' \
  '{"timestamp":"hidden-event","fields":{"event":"tool_call","tool":"BashCommand","action":"command","outcome":"ok"}}' \
  >>"$runtime/runtime/usage.jsonl"
! rg -q hidden-event "$test_root/foreground.out"
printf 'v' >&9
for _ in {1..40}; do
  rg -q 'winx-code-agent> <list>' "$test_root/commands.log" && break
  sleep 0.1
done
rg -q 'winx-code-agent> <list>' "$test_root/commands.log"
[[ -f "$test_root/list-before-ready" ]]
sleep 0.2
! rg -q synthetic-shell-output "$test_root/foreground.out"
! rg -q 'Could not read Winx shell output' "$test_root/foreground.out"
printf '%s\n' \
  '{"timestamp":"visible-event","fields":{"event":"tool_call","tool":"BashCommand","action":"command","outcome":"ok"}}' \
  >>"$runtime/runtime/usage.jsonl"
for _ in {1..40}; do
  rg -q visible-event "$test_root/foreground.out" && break
  sleep 0.1
done
rg -q visible-event "$test_root/foreground.out"
touch "$test_root/winx-ready"
for _ in {1..40}; do
  rg -q synthetic-shell-output "$test_root/foreground.out" && break
  sleep 0.1
done
rg -q synthetic-shell-output "$test_root/foreground.out"
printf 'v' >&9
for _ in {1..40}; do
  rg -q 'Press v to show it again' "$test_root/foreground.out" && break
  sleep 0.1
done
rg -q 'Press v to show it again' "$test_root/foreground.out"
printf '%s\n' \
  '{"timestamp":"after-hide","fields":{"event":"tool_call","tool":"BashCommand","action":"command","outcome":"ok"}}' \
  >>"$runtime/runtime/usage.jsonl"
attach_count="$(rg -c 'winx-code-agent> <attach>' "$test_root/commands.log")"
sleep 1.5
[[ "$(rg -c 'winx-code-agent> <attach>' "$test_root/commands.log")" -eq "$attach_count" ]]
! rg -q after-hide "$test_root/foreground.out"
kill -TERM "$(<"$test_root/foreground.pid")"
wait "$foreground_pid" || true
foreground_pid=""
exec 9>&-
[[ ! -f "$test_root/container-running" ]]
rg -q 'Stopping MCP and Secure Tunnel' \
  "$test_root/foreground.out"
! rg -q 'Could not read Winx shell output' \
  "$test_root/foreground.out"
! rg -q hidden-event "$test_root/foreground.out"

# Activity output includes the tool and outcome, but omits arguments.
: >"$test_root/usage.jsonl"
bash "$repo_root/ai-sandbox/mcp/activity.sh" \
  "$test_root/usage.jsonl" \
  >"$test_root/activity.out" &
activity_pid=$!
sleep 0.1
printf '%s\n' \
  '{"timestamp":"synthetic-time","fields":{"event":"tool_call","tool":"BashCommand","action":"command","outcome":"ok","command":"private-test-argument"}}' \
  >>"$test_root/usage.jsonl"
for _ in {1..20}; do
  rg -q 'BashCommand command ok' "$test_root/activity.out" && break
  sleep 0.1
done
kill "$activity_pid"
wait "$activity_pid" || true
activity_pid=""
rg -q 'BashCommand command ok' "$test_root/activity.out"
! rg -q private-test-argument "$test_root/activity.out"

# Android controller mode keeps the dedicated MCP home and reaches host adb.
: >"$test_root/commands.log"
if ! "$ai_sandbox" mcp "$workspace" --tunnel --android --detach \
  >"$test_root/android-start.out" 2>"$test_root/android-start.err"; then
  cat "$test_root/android-start.err" >&2
  exit 1
fi
rg -F '<--network> <host>' "$test_root/commands.log" >/dev/null
rg -F '<ADB_SERVER_SOCKET=tcp:127.0.0.1:5037>' \
  "$test_root/commands.log" >/dev/null
rg -F "<$AI_SANDBOX_ANDROID_STATE_DIR:/android-state>" \
  "$test_root/commands.log" >/dev/null
rg -F "<$runtime:/sandbox-home>" "$test_root/commands.log" >/dev/null
jq -e '.profile == "android" and .reuse_emulator == false' \
  "$runtime/runtime/metadata.json" >/dev/null
"$ai_sandbox" mcp "$workspace" --status --json >"$test_root/android-status.json"
jq -e '.profile == "android" and .health == "ok"' \
  "$test_root/android-status.json" >/dev/null
: >"$test_root/commands.log"
"$ai_sandbox" mcp "$workspace" --tunnel --detach \
  >"$test_root/android-repeat.out" 2>"$test_root/android-repeat.err"
rg -q 'already running' "$test_root/android-repeat.err"
if rg -q '^podman <run>|^podman <start>' "$test_root/commands.log"; then
  echo "Repeated Android MCP start created another container" >&2
  exit 1
fi
: >"$test_root/commands.log"
"$ai_sandbox" mcp "$workspace" --stop >"$test_root/android-stop.out"
[[ ! -f "$test_root/container-running" ]]
