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
export AI_SANDBOX_AUTO_RECONNECT=0
export AI_SANDBOX_TEST_ROOT="$test_root"
export PATH="$test_root/bin:/usr/bin:/bin"
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
runtime="$(find "$AI_SANDBOX_HOME_STORAGE/.ai-sandbox/mcp-winx" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)"
case "${1:-}" in
  image) exit 0 ;;
  run) touch "$state"; echo synthetic-container-id; exit 0 ;;
  start) touch "$state"; exit 0 ;;
  stop) rm -f "$state"; exit 0 ;;
  inspect)
    [[ "$*" == *-mcp-* ]] || exit 1
    [[ -f "$state" ]] || exit 1
    case "$*" in
      *State.Status*) echo running ;;
      *State.Running*) echo true ;;
      *HostConfig.NetworkMode*) echo bridge ;;
      *Config.Env*) echo AI_SANDBOX_NETWORK_MODE=bridge ;;
      *Id*) echo synthetic-container-id ;;
    esac
    exit 0
    ;;
  exec)
    case "$*" in
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

if "$ai_sandbox" mcp "$workspace" --local \
  >"$test_root/invalid.out" 2>"$test_root/invalid.err"; then
  echo "Legacy local HTTP mode was accepted" >&2
  exit 1
fi
rg -q 'stdio through Secure Tunnel' "$test_root/invalid.err"

if "$ai_sandbox" mcp "$workspace" --network host --tunnel \
  >"$test_root/invalid.out" 2>"$test_root/invalid.err"; then
  echo "Host networking was accepted" >&2
  exit 1
fi
rg -q 'bridge networking' "$test_root/invalid.err"

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
