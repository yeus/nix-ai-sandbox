#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ai_sandbox="$repo_root/ai-sandbox/ai-sandbox"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

export AI_SANDBOX_STATE_DIR="$test_root/state"
export AI_SANDBOX_HOME_STORAGE="$test_root/home"
export AI_SANDBOX_NIX_STORAGE="$test_root/nix"
export AI_SANDBOX_TEST_PODMAN_STATE="$test_root/podman-running"
export AI_SANDBOX_TEST_COMMAND_LOG="$test_root/commands.log"
export AI_SANDBOX_TEST_OP_LOG="$test_root/operations.log"

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'podman %s\n' "$*" >>"$AI_SANDBOX_TEST_COMMAND_LOG"

if [[ "${1:-}" == "ps" ]]; then
  echo fake-container
  exit 0
fi

if [[ "${1:-}" == "inspect" ]]; then
  template="${3:-}"
  if [[ "$template" == *Config.Env* ]]; then
    echo "AI_SANDBOX_NETWORK_MODE=${AI_SANDBOX_TEST_NETWORK_MODE:-host}"
  elif [[ "$template" == *State.Status* ]]; then
    [[ -e "$AI_SANDBOX_TEST_PODMAN_STATE" ]] || exit 1
    echo running
  elif [[ "$template" == *State.Running* ]]; then
    echo true
  elif [[ "$template" == *HostConfig.NetworkMode* ]]; then
    echo "${AI_SANDBOX_TEST_NETWORK_MODE:-host}"
  fi
  exit 0
fi

if [[ "${1:-}" == "exec" ]]; then
  script="${!#}"
  if [[ "$script" == *"cat >/etc/resolv.conf"* ]]; then
    echo sync >>"$AI_SANDBOX_TEST_OP_LOG"
    touch "$AI_SANDBOX_TEST_PODMAN_STATE.resolver-synced"
    exit 0
  fi
  if [[ "$script" == *getent* ]]; then
    echo dns >>"$AI_SANDBOX_TEST_OP_LOG"
    if [[ "${AI_SANDBOX_TEST_DNS:-ok}" == fail &&
      ( "${AI_SANDBOX_TEST_DNS_AFTER_SYNC:-fail}" != ok ||
        ! -e "$AI_SANDBOX_TEST_PODMAN_STATE.resolver-synced" ) ]]; then
      [[ "$script" == *"timeout 3s"* ]] || sleep 10
      exit 1
    fi
    exit 0
  fi
  if [[ "$script" == *curl* ]]; then
    echo ip >>"$AI_SANDBOX_TEST_OP_LOG"
    [[ "${AI_SANDBOX_TEST_IP:-ok}" == ok ]]
    exit $?
  fi
  exit 0
fi

if [[ "${1:-}" == "image" ]]; then
  exit 0
fi

if [[ "${1:-}" == "run" && "${2:-}" == "-d" ]]; then
  touch "$AI_SANDBOX_TEST_PODMAN_STATE"
  echo fake-container
  exit 0
fi

if [[ "${1:-}" == "logs" ]]; then
  echo 'AI_SANDBOX_READY_VSCODE: fake'
  exit 0
fi

if [[ "${1:-}" == "stop" ]]; then
  rm -f "$AI_SANDBOX_TEST_PODMAN_STATE"
fi
exit 0
EOF

cat >"$fake_bin/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == route ]]; then
  echo 'default via 192.0.2.1 dev eth0'
fi
EOF

chmod +x "$fake_bin/podman" "$fake_bin/ip"
export PATH="$fake_bin:/usr/bin:/bin"

run_manual_reconnect() {
  rm -f "$AI_SANDBOX_TEST_PODMAN_STATE.resolver-synced"
  : >"$AI_SANDBOX_TEST_COMMAND_LOG"
  : >"$AI_SANDBOX_TEST_OP_LOG"
  set +e
  timeout 4s "$ai_sandbox" reconnect-network "$repo_root" \
    >"$test_root/reconnect.out" 2>"$test_root/reconnect.err"
  reconnect_status=$?
  set -e
  [[ "$reconnect_status" -ne 124 ]] || {
    echo "reconnect-network exceeded its probe timeout" >&2
    exit 1
  }
}

export AI_SANDBOX_TEST_NETWORK_MODE=host
export AI_SANDBOX_TEST_DNS=fail
export AI_SANDBOX_TEST_IP=ok
unset AI_SANDBOX_TEST_DNS_AFTER_SYNC
run_manual_reconnect
[[ "$reconnect_status" -eq 2 ]]
grep -F 'timeout 3s getent hosts api.openai.com' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"

sync_line="$(grep -n '^sync$' "$AI_SANDBOX_TEST_OP_LOG" | head -n1 | cut -d: -f1)"
dns_line="$(grep -n '^dns$' "$AI_SANDBOX_TEST_OP_LOG" | head -n1 | cut -d: -f1)"
ip_line="$(grep -n '^ip$' "$AI_SANDBOX_TEST_OP_LOG" | head -n1 | cut -d: -f1)"
[[ "$sync_line" -lt "$dns_line" && "$dns_line" -lt "$ip_line" ]]
if grep -E '^podman (restart|stop|rm|run|start)( |$)' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"; then
  echo "reconnect-network changed the container lifecycle" >&2
  exit 1
fi

export AI_SANDBOX_TEST_NETWORK_MODE=bridge
export AI_SANDBOX_TEST_DNS=ok
export AI_SANDBOX_TEST_IP=ok
run_manual_reconnect
[[ "$reconnect_status" -eq 0 ]]
if grep -q '^sync$' "$AI_SANDBOX_TEST_OP_LOG"; then
  echo "bridge reconnect unexpectedly synchronized the host resolver" >&2
  exit 1
fi
grep -q '^dns$' "$AI_SANDBOX_TEST_OP_LOG"
grep -q '^ip$' "$AI_SANDBOX_TEST_OP_LOG"

run_watcher() {
  rm -rf "$AI_SANDBOX_STATE_DIR"
  rm -f "$AI_SANDBOX_TEST_PODMAN_STATE" \
    "$AI_SANDBOX_TEST_PODMAN_STATE.resolver-synced"
  : >"$AI_SANDBOX_TEST_COMMAND_LOG"
  : >"$AI_SANDBOX_TEST_OP_LOG"
  XDG_DATA_HOME="$test_root/xdg-data" \
    AI_SANDBOX_AUTO_RECONNECT=1 \
    AI_SANDBOX_AUTO_RECONNECT_INTERVAL=2 \
    "$ai_sandbox" start "$repo_root" >"$test_root/start.out"

  watcher_pid_file="$(find "$AI_SANDBOX_STATE_DIR" \
    -name 'network-watcher-*.pid' -print -quit)"
  [[ -n "$watcher_pid_file" ]]
  sleep 3
  watcher_pid="$(<"$watcher_pid_file")"
  kill "$watcher_pid" 2>/dev/null || true
  sleep 1
}

export AI_SANDBOX_TEST_NETWORK_MODE=host
export AI_SANDBOX_TEST_DNS=ok
export AI_SANDBOX_TEST_IP=ok
run_watcher
if grep -q '^sync$' "$AI_SANDBOX_TEST_OP_LOG"; then
  echo "healthy watcher performed an unnecessary resolver sync" >&2
  exit 1
fi
grep -q '^dns$' "$AI_SANDBOX_TEST_OP_LOG"

export AI_SANDBOX_TEST_DNS=fail
export AI_SANDBOX_TEST_DNS_AFTER_SYNC=ok
export AI_SANDBOX_TEST_IP=ok
run_watcher
grep -q '^sync$' "$AI_SANDBOX_TEST_OP_LOG"

echo "ai-sandbox network reconnect tests passed"
