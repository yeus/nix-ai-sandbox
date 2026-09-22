#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ai_sandbox="$repo_root/ai-sandbox/ai-sandbox"
test_root="$(mktemp -d)"
listener_pid=""
cleanup() {
  [[ -z "$listener_pid" ]] || kill "$listener_pid" 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup EXIT

workspace="$test_root/workspace"
mkdir -p "$workspace"
git -C "$workspace" init -q

export AI_SANDBOX_STATE_DIR="$test_root/state"
export AI_SANDBOX_HOME_STORAGE="$test_root/home"
export AI_SANDBOX_NIX_STORAGE="$test_root/nix"
export AI_SANDBOX_AUTO_RECONNECT=0
export AI_SANDBOX_TEST_PODMAN_STATE="$test_root/container-running"
export AI_SANDBOX_TEST_COMMAND_LOG="$test_root/commands.log"

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'podman' >>"$AI_SANDBOX_TEST_COMMAND_LOG"
printf ' <%s>' "$@" >>"$AI_SANDBOX_TEST_COMMAND_LOG"
printf '\n' >>"$AI_SANDBOX_TEST_COMMAND_LOG"

case "${1:-} ${2:-}" in
  "image exists") exit 0 ;;
  "run -d")
    touch "$AI_SANDBOX_TEST_PODMAN_STATE"
    echo fake-container-id
    exit 0
    ;;
esac

if [[ "${1:-}" == inspect ]]; then
  [[ -f "$AI_SANDBOX_TEST_PODMAN_STATE" ]] || exit 1
  if [[ "${2:-}" == -f ]]; then
    case "${3:-}" in
      *State.Status*) echo running ;;
      *State.Running*) echo true ;;
      *HostConfig.NetworkMode*) echo host ;;
      *Config.Env*)
        echo AI_SANDBOX_NETWORK_MODE=host
        echo AI_SANDBOX_WORKSPACE=/workspace
        ;;
      *Id*) echo fake-container-id ;;
    esac
  fi
  exit 0
fi

if [[ "${1:-}" == exec ]]; then
  args="$*"
  if [[ "$args" == *ai-sandbox-mcp-tunnel-start* ]]; then
    tail="${args#*ai-sandbox-mcp-tunnel-start }"
    runtime="${tail%% *}"
    tail="${tail#* }"
    version="${tail%% *}"
    tail="${tail#* }"
    tunnel_id="${tail%% *}"
    runtime="${runtime#/sandbox-home/.ai-sandbox/mcp/}"
    tunnel_dir="$AI_SANDBOX_HOME_STORAGE/.ai-sandbox/mcp/$runtime/tunnel"
    mkdir -p "$tunnel_dir"
    jq -n \
      --arg tunnel_id "$tunnel_id" \
      --arg version "$version" \
      '{configured: true, tunnel_id: $tunnel_id, version: $version, transport: "OpenAI Secure MCP Tunnel", process_running: true, healthy: true, ready: true, health_url: "http://127.0.0.1:18080", ui_url: "http://127.0.0.1:18080/ui"}' \
      >"$tunnel_dir/metadata.json"
    touch "$tunnel_dir/running"
  elif [[ "$args" == *ai-sandbox-mcp-tunnel-status* ]]; then
    tail="${args#*ai-sandbox-mcp-tunnel-status }"
    runtime="${tail%% *}"
    runtime="${runtime#/sandbox-home/.ai-sandbox/mcp/}"
    tunnel_dir="$AI_SANDBOX_HOME_STORAGE/.ai-sandbox/mcp/$runtime/tunnel"
    if [[ ! -f "$tunnel_dir/metadata.json" ]]; then
      echo '{"configured":false,"process_running":false,"healthy":false,"ready":false}'
    elif [[ -f "$tunnel_dir/running" ]]; then
      cat "$tunnel_dir/metadata.json"
    else
      jq '. + {process_running: false, healthy: false, ready: false}' \
        "$tunnel_dir/metadata.json"
    fi
  elif [[ "$args" == *ai-sandbox-mcp-tunnel-stop* ]]; then
    if [[ "${AI_SANDBOX_TEST_TUNNEL_STOP_FAILS:-0}" == 1 ]]; then
      exit 0
    fi
    tail="${args#*ai-sandbox-mcp-tunnel-stop }"
    runtime="${tail%% *}"
    runtime="${runtime#/sandbox-home/.ai-sandbox/mcp/}"
    rm -f "$AI_SANDBOX_HOME_STORAGE/.ai-sandbox/mcp/$runtime/tunnel/running"
  elif [[ "$args" == *ai-sandbox-mcp-launch* ]]; then
    runtime="${args#* /sandbox-home/.ai-sandbox/mcp/}"
    runtime="${runtime%% *}"
    runtime_dir="$AI_SANDBOX_HOME_STORAGE/.ai-sandbox/mcp/$runtime"
    mkdir -p "$runtime_dir/runtime"
    printf '4242\n' >"$runtime_dir/runtime/pid"
  elif [[ "$args" == *ai-sandbox-mcp-status* ]]; then
    runtime="${args#* /sandbox-home/.ai-sandbox/mcp/}"
    runtime="${runtime%% *}"
    pid_file="$AI_SANDBOX_HOME_STORAGE/.ai-sandbox/mcp/$runtime/runtime/pid"
    if [[ ! -s "$pid_file" ]]; then
      echo stopped
    elif [[ "$(<"$pid_file")" == 999999 ]]; then
      echo stale
    else
      echo running
    fi
  elif [[ "$args" == *ai-sandbox-mcp-stop* ]]; then
    runtime="${args#* /sandbox-home/.ai-sandbox/mcp/}"
    runtime="${runtime%% *}"
    rm -f "$AI_SANDBOX_HOME_STORAGE/.ai-sandbox/mcp/$runtime/runtime/pid"
  fi
  exit 0
fi

exit 0
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$fake_bin/podman" "$fake_bin/curl"
export PATH="$fake_bin:/usr/bin:/bin"

"$ai_sandbox" help >"$test_root/help.txt"
grep -F 'ai-sandbox mcp [WORKSPACE]' "$test_root/help.txt"
grep -F -- '--read-only' "$test_root/help.txt"
grep -F -- '--ship' "$test_root/help.txt"
grep -F -- '--tunnel TUNNEL_ID' "$test_root/help.txt"
grep -F -- '--status' "$test_root/help.txt"
grep -F -- '--json' "$test_root/help.txt"

if "$ai_sandbox" mcp "$workspace" --read-only --ship \
  >"$test_root/conflict.out" 2>"$test_root/conflict.err"; then
  echo "mcp unexpectedly accepted conflicting permission modes" >&2
  exit 1
fi
grep -F 'mutually exclusive' "$test_root/conflict.err"

if "$ai_sandbox" mcp "$workspace" --local \
  --tunnel tunnel_0123456789abcdef0123456789abcdef \
  >"$test_root/transport-conflict.out" \
  2>"$test_root/transport-conflict.err"; then
  echo "mcp unexpectedly accepted conflicting transports" >&2
  exit 1
fi
grep -F 'mutually exclusive' \
  "$test_root/transport-conflict.err"

if "$ai_sandbox" mcp "$workspace" \
  --tunnel not-a-tunnel \
  >"$test_root/tunnel-id.out" \
  2>"$test_root/tunnel-id.err"; then
  echo "mcp unexpectedly accepted an invalid tunnel ID" >&2
  exit 1
fi
grep -F 'Invalid --tunnel value' \
  "$test_root/tunnel-id.err"

if AI_SANDBOX_NETWORK_MODE=bridge \
  "$ai_sandbox" mcp "$workspace" \
  >"$test_root/bridge.out" 2>"$test_root/bridge.err"; then
  echo "mcp unexpectedly accepted bridge networking" >&2
  exit 1
fi
grep -F 'mcp requires host networking' "$test_root/bridge.err"

if "$ai_sandbox" mcp "$workspace" --instance extra \
  >"$test_root/instance.out" 2>"$test_root/instance.err"; then
  echo "mcp unexpectedly accepted --instance" >&2
  exit 1
fi
grep -F 'one MCP process is allowed per workspace' \
  "$test_root/instance.err"

if "$ai_sandbox" mcp "$workspace" "$workspace" \
  >"$test_root/workspaces.out" 2>"$test_root/workspaces.err"; then
  echo "mcp unexpectedly accepted multiple workspaces" >&2
  exit 1
fi
grep -F 'at most one WORKSPACE' "$test_root/workspaces.err"

submodule_source="$test_root/submodule-source"
parent_workspace="$test_root/parent-workspace"
mkdir -p "$submodule_source" "$parent_workspace"
git -C "$submodule_source" init -q
printf 'fixture\n' >"$submodule_source/README.md"
git -C "$submodule_source" add README.md
git -C "$submodule_source" \
  -c user.name=Fixture \
  -c user.email=fixture@example.invalid \
  commit -qm fixture
git -C "$parent_workspace" init -q
git -c protocol.file.allow=always \
  -C "$parent_workspace" \
  submodule add -q "$submodule_source" child
if "$ai_sandbox" mcp "$parent_workspace/child" \
  >"$test_root/submodule.out" 2>"$test_root/submodule.err"; then
  echo "mcp unexpectedly exposed an expanded parent mount" >&2
  exit 1
fi
grep -F 'cannot expose a submodule' "$test_root/submodule.err"

: >"$AI_SANDBOX_TEST_COMMAND_LOG"
mkdir -p "$AI_SANDBOX_STATE_DIR"
printf 'interactive-container\n' >"$AI_SANDBOX_STATE_DIR/last-container"
"$ai_sandbox" mcp "$workspace" --port 18787 \
  >"$test_root/start.out" 2>"$test_root/start.err"
grep -F 'Mode: write' "$test_root/start.out"
grep -F 'Endpoint: http://127.0.0.1:18787/mcp' "$test_root/start.out"
grep -F 'Health: OK' "$test_root/start.out"
grep -F '986f2135f00959f8e0d214ed8d173a7054f4cea1' \
  "$test_root/start.out"
[[ "$(<"$AI_SANDBOX_STATE_DIR/last-container")" == interactive-container ]]

workspace_hash="$(printf '%s' "$workspace" | sha256sum | cut -c1-12)"
runtime_dir="$AI_SANDBOX_HOME_STORAGE/.ai-sandbox/mcp/$workspace_hash"
jq -e '.repos | length == 1' "$runtime_dir/config.json" >/dev/null
jq -e '.repos[0].repo_id == "workspace"' "$runtime_dir/config.json" >/dev/null
jq -e '.repos[0].root == "/workspace"' "$runtime_dir/config.json" >/dev/null
jq -e '.repos[0].writes.enabled == true' "$runtime_dir/config.json" >/dev/null
[[ ! -e "$workspace/config.json" && ! -e "$workspace/.chatgpt" ]]

grep -F '<--network> <host>' "$AI_SANDBOX_TEST_COMMAND_LOG"
grep -F "$runtime_dir/upstream-runtime:/workspace/.chatgpt" \
  "$AI_SANDBOX_TEST_COMMAND_LOG"
if grep -E -- '--privileged|podman.sock|/run/podman|/var/run/docker.sock' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"; then
  echo "mcp startup weakened the container boundary" >&2
  exit 1
fi

: >"$AI_SANDBOX_TEST_COMMAND_LOG"
"$ai_sandbox" mcp "$workspace" \
  >"$test_root/repeat.out" 2>"$test_root/repeat.err"
grep -F 'already running' "$test_root/repeat.err"
if grep -F '<run> <-d>' "$AI_SANDBOX_TEST_COMMAND_LOG"; then
  echo "repeated mcp start created a duplicate container" >&2
  exit 1
fi
if grep -E 'ai-sandbox-mcp-(install|launch)' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"; then
  echo "repeated mcp start relaunched the implementation" >&2
  exit 1
fi

if "$ai_sandbox" mcp "$workspace" --read-only \
  >"$test_root/mode-change.out" 2>"$test_root/mode-change.err"; then
  echo "running MCP unexpectedly changed permission mode" >&2
  exit 1
fi
grep -F 'Stop it before changing mode or port' \
  "$test_root/mode-change.err"

"$ai_sandbox" mcp "$workspace" --status --json >"$test_root/status.json"
jq -e '.workspace == $workspace' \
  --arg workspace "$workspace" "$test_root/status.json" >/dev/null
jq -e '.mode == "write" and .health == "ok"' \
  "$test_root/status.json" >/dev/null

if env -u CONTROL_PLANE_API_KEY \
  "$ai_sandbox" mcp "$workspace" \
  --tunnel tunnel_0123456789abcdef0123456789abcdef \
  >"$test_root/tunnel-key.out" \
  2>"$test_root/tunnel-key.err"; then
  echo "mcp tunnel unexpectedly started without a runtime key" >&2
  exit 1
fi
grep -F 'CONTROL_PLANE_API_KEY is required' \
  "$test_root/tunnel-key.err"

: >"$AI_SANDBOX_TEST_COMMAND_LOG"
CONTROL_PLANE_API_KEY=sk-synthetic-test-value \
  "$ai_sandbox" mcp "$workspace" \
  --tunnel tunnel_0123456789abcdef0123456789abcdef \
  --json >"$test_root/tunnel.json"
jq -e '.tunnel.tunnel_id == "tunnel_0123456789abcdef0123456789abcdef"' \
  "$test_root/tunnel.json" >/dev/null
jq -e '.tunnel.process_running and .tunnel.healthy and .tunnel.ready' \
  "$test_root/tunnel.json" >/dev/null
grep -F '<-e> <CONTROL_PLANE_API_KEY>' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"
grep -F 'ai-sandbox-mcp-tunnel-install' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"
grep -F 'ai-sandbox-mcp-tunnel-start' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"
if grep -R -F 'sk-synthetic-test-value' "$runtime_dir"; then
  echo "MCP tunnel persisted the runtime key" >&2
  exit 1
fi
if grep -F 'sk-synthetic-test-value' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"; then
  echo "MCP tunnel exposed the runtime key in argv" >&2
  exit 1
fi

: >"$AI_SANDBOX_TEST_COMMAND_LOG"
CONTROL_PLANE_API_KEY=sk-synthetic-test-value \
  "$ai_sandbox" mcp "$workspace" \
  --tunnel tunnel_0123456789abcdef0123456789abcdef \
  --json >"$test_root/tunnel-repeat.json" \
  2>"$test_root/tunnel-repeat.err"
grep -F 'Secure MCP Tunnel is already running' \
  "$test_root/tunnel-repeat.err"
jq -e '.tunnel.process_running' \
  "$test_root/tunnel-repeat.json" >/dev/null
if grep -E 'ai-sandbox-mcp-tunnel-(install|start)' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"; then
  echo "repeated tunnel start relaunched the tunnel client" >&2
  exit 1
fi

: >"$AI_SANDBOX_TEST_COMMAND_LOG"
if CONTROL_PLANE_API_KEY=sk-synthetic-test-value \
  "$ai_sandbox" mcp "$workspace" \
  --tunnel tunnel_ffffffffffffffffffffffffffffffff \
  >"$test_root/tunnel-change.out" \
  2>"$test_root/tunnel-change.err"; then
  echo "mcp unexpectedly switched an active tunnel" >&2
  exit 1
fi
grep -F 'Stop it before changing tunnels' \
  "$test_root/tunnel-change.err"
if grep -E 'ai-sandbox-mcp-tunnel-(install|start)' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"; then
  echo "conflicting tunnel request relaunched the tunnel client" >&2
  exit 1
fi

"$ai_sandbox" mcp "$workspace" \
  --status --json >"$test_root/tunnel-status.json"
jq -e '.tunnel.transport == "OpenAI Secure MCP Tunnel"' \
  "$test_root/tunnel-status.json" >/dev/null
jq -e '.tunnel.version == "v0.0.14"' \
  "$test_root/tunnel-status.json" >/dev/null

if "$ai_sandbox" mcp "$workspace" --local \
  >"$test_root/local-change.out" \
  2>"$test_root/local-change.err"; then
  echo "mcp unexpectedly disabled an active tunnel implicitly" >&2
  exit 1
fi
grep -F 'Stop it before switching to local-only transport' \
  "$test_root/local-change.err"

jq '.version = "v9.9.9"' \
  "$runtime_dir/tunnel/metadata.json" >"$test_root/tunnel-metadata.json"
mv "$test_root/tunnel-metadata.json" "$runtime_dir/tunnel/metadata.json"

: >"$AI_SANDBOX_TEST_COMMAND_LOG"
if AI_SANDBOX_TEST_TUNNEL_STOP_FAILS=1 \
  "$ai_sandbox" mcp "$workspace" --stop --json \
  >"$test_root/stop-fail.json" 2>"$test_root/stop-fail.err"; then
  echo "mcp --stop reported success while the tunnel kept running" >&2
  exit 1
fi
jq -e '.tunnel.process_running == true' \
  "$test_root/stop-fail.json" >/dev/null
grep -F 'Secure MCP Tunnel is still running' \
  "$test_root/stop-fail.err"
grep -F '<v9.9.9>' "$AI_SANDBOX_TEST_COMMAND_LOG"
[[ -f "$runtime_dir/tunnel/running" ]]

: >"$AI_SANDBOX_TEST_COMMAND_LOG"
"$ai_sandbox" mcp "$workspace" --stop >"$test_root/stop.out"
grep -F 'Stopped Secure MCP Tunnel' "$test_root/stop.out"
grep -F '<v9.9.9>' "$AI_SANDBOX_TEST_COMMAND_LOG"
[[ -f "$AI_SANDBOX_TEST_PODMAN_STATE" ]]
[[ ! -f "$runtime_dir/tunnel/running" ]]

"$ai_sandbox" mcp "$workspace" --status --json >"$test_root/stopped.json"
jq -e '.health == "stopped"' "$test_root/stopped.json" >/dev/null
jq -e '.tunnel.process_running == false' \
  "$test_root/stopped.json" >/dev/null

"$ai_sandbox" mcp "$workspace" --read-only --json \
  >"$test_root/read.json" 2>"$test_root/read.err"
jq -e '.mode == "read" and .health == "ok"' \
  "$test_root/read.json" >/dev/null
jq -e '.repos[0].writes.enabled == false' \
  "$runtime_dir/config.json" >/dev/null
"$ai_sandbox" mcp "$workspace" --stop >/dev/null

"$ai_sandbox" mcp "$workspace" --ship --json \
  >"$test_root/ship.json" 2>"$test_root/ship.err"
jq -e '.mode == "ship" and .health == "ok"' \
  "$test_root/ship.json" >/dev/null
jq -e '.repos[0].operations.git_commit_enabled == true' \
  "$runtime_dir/config.json" >/dev/null
"$ai_sandbox" mcp "$workspace" --stop >/dev/null

python3 -m http.server 18788 --bind 127.0.0.1 \
  >"$test_root/listener.log" 2>&1 &
listener_pid=$!
for _ in {1..20}; do
  (exec 3<>/dev/tcp/127.0.0.1/18788) 2>/dev/null && break
  sleep 0.05
done
if "$ai_sandbox" mcp "$workspace" --port 18788 \
  >"$test_root/collision.out" 2>"$test_root/collision.err"; then
  echo "mcp unexpectedly accepted an occupied port" >&2
  exit 1
fi
grep -F 'MCP port 18788 is already in use' \
  "$test_root/collision.err"
kill "$listener_pid"
wait "$listener_pid" 2>/dev/null || true
listener_pid=""

echo '999999' >"$runtime_dir/runtime/pid"
"$ai_sandbox" mcp "$workspace" --status --json >"$test_root/stale.json"
jq -e '.health == "stale"' "$test_root/stale.json" >/dev/null

echo "ai-sandbox MCP CLI tests passed"
