#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ai_sandbox="$repo_root/ai-sandbox/ai-sandbox"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export AI_SANDBOX_STATE_DIR="$test_root/state"
export AI_SANDBOX_HOME_STORAGE="$test_root/home"
export AI_SANDBOX_NIX_STORAGE="$test_root/nix"

"$ai_sandbox" help >"$test_root/help.txt"
grep -F 'ai-sandbox serve [WORKSPACE]' "$test_root/help.txt"
grep -F -- '--only all|codex|opencode|vscode|code-server' "$test_root/help.txt"

if AI_SANDBOX_NETWORK_MODE=bridge \
  "$ai_sandbox" serve "$repo_root" >"$test_root/bridge.out" 2>"$test_root/bridge.err"; then
  echo "serve unexpectedly accepted bridge networking" >&2
  exit 1
fi
grep -F 'serve requires host networking' "$test_root/bridge.err"

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
export AI_SANDBOX_TEST_PODMAN_STATE="$test_root/podman-running"
export AI_SANDBOX_TEST_COMMAND_LOG="$test_root/commands.log"

cat >"$fake_bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'podman' >>"$AI_SANDBOX_TEST_COMMAND_LOG"
printf ' <%s>' "$@" >>"$AI_SANDBOX_TEST_COMMAND_LOG"
printf '\n' >>"$AI_SANDBOX_TEST_COMMAND_LOG"
case "${1:-} ${2:-}" in
  "image exists")
    exit 0
    ;;
  "run -d")
    touch "$AI_SANDBOX_TEST_PODMAN_STATE"
    echo fake-container-id
    exit 0
    ;;
esac
if [[ "${1:-}" == "inspect" ]]; then
  [[ -f "$AI_SANDBOX_TEST_PODMAN_STATE" ]] || exit 1
  if [[ "${2:-}" == "-f" ]]; then
    case "${3:-}" in
      *State.Status*) echo running ;;
      *State.Running*) echo true ;;
      *NetworkMode*) echo host ;;
    esac
  fi
  exit 0
fi
if [[ "${1:-}" == "stop" ]]; then
  rm -f "$AI_SANDBOX_TEST_PODMAN_STATE"
fi
exit 0
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fake_bin/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$fake_bin/podman" "$fake_bin/curl" "$fake_bin/ss"
export PATH="$fake_bin:/usr/bin:/bin"
export AI_SANDBOX_AUTO_RECONNECT=0

"$ai_sandbox" serve "$repo_root" >"$test_root/serve-first.out"
grep -F 'AI_SANDBOX_READY_CODE_SERVER: http://127.0.0.1:' "$test_root/serve-first.out"
grep -F '<AI_SANDBOX_MODE=server>' "$AI_SANDBOX_TEST_COMMAND_LOG"
grep -F '<AI_SANDBOX_CODE_SERVER_PORT=' "$AI_SANDBOX_TEST_COMMAND_LOG"
if grep -E '/tmp/\\.X11-unix|/dev/dri|host-run-user-bus' "$AI_SANDBOX_TEST_COMMAND_LOG"; then
  echo "serve unexpectedly passed desktop integration mounts" >&2
  exit 1
fi

first_port="$(awk -F: '/AI_SANDBOX_READY_CODE_SERVER: http/{print $NF}' "$test_root/serve-first.out" | tail -n1)"
rm -f "$AI_SANDBOX_TEST_PODMAN_STATE"
: >"$AI_SANDBOX_TEST_COMMAND_LOG"
"$ai_sandbox" serve "$repo_root" >"$test_root/serve-second.out"
second_port="$(awk -F: '/AI_SANDBOX_READY_CODE_SERVER: http/{print $NF}' "$test_root/serve-second.out" | tail -n1)"
[[ -n "$first_port" && "$first_port" == "$second_port" ]]

"$ai_sandbox" serve "$repo_root" --stop >"$test_root/serve-stop.out"
grep -F 'Stopped code-server container' "$test_root/serve-stop.out"

echo "ai-sandbox serve CLI tests passed"
