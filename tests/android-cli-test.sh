#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ai_sandbox="$repo_root/ai-sandbox/ai-sandbox"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

export AI_SANDBOX_STATE_DIR="$test_root/state"
export AI_SANDBOX_HOME_STORAGE="$test_root/home"
export AI_SANDBOX_NIX_STORAGE="$test_root/nix"
export AI_SANDBOX_ANDROID_STATE_DIR="$test_root/android"
export AI_SANDBOX_AUTO_RECONNECT=0
export XDG_DATA_HOME="$test_root/xdg-data"
export DISPLAY=:0

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
  "run --rm")
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

if [[ "${1:-}" == "logs" ]]; then
  echo "AI_SANDBOX_READY_VSCODE: fake"
  exit 0
fi

exit 0
EOF

chmod +x "$fake_bin/podman"
export PATH="$fake_bin:/usr/bin:/bin"

"$ai_sandbox" help >"$test_root/help.txt"
grep -F -- '--android' "$test_root/help.txt"
grep -F -- '--emulator' "$test_root/help.txt"
grep -F -- '--android-emulator' "$test_root/help.txt"
grep -F -- '--android-gpu' "$test_root/help.txt"
grep -F 'ai-sandbox android-doctor' "$test_root/help.txt"

rm -f "$AI_SANDBOX_TEST_PODMAN_STATE" "$AI_SANDBOX_TEST_COMMAND_LOG"
"$ai_sandbox" start "$repo_root" >"$test_root/default.out"
if grep -E '<--device(=|>)|/dev/dri|/dev/kvm|ADB_SERVER_SOCKET|ANDROID_' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"; then
  echo "default startup unexpectedly received Android or GPU access" >&2
  exit 1
fi
if grep -F -- '--privileged' "$AI_SANDBOX_TEST_COMMAND_LOG"; then
  echo "default startup unexpectedly used --privileged" >&2
  exit 1
fi

rm -f "$AI_SANDBOX_TEST_PODMAN_STATE" "$AI_SANDBOX_TEST_COMMAND_LOG"
"$ai_sandbox" start "$repo_root" --android >"$test_root/android.out"
grep -F '<--network> <host>' "$AI_SANDBOX_TEST_COMMAND_LOG"
grep -F '<-e> <ADB_SERVER_SOCKET=tcp:127.0.0.1:5037>' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"
grep -F '<-e> <AI_SANDBOX_ANDROID_MODE=1>' "$AI_SANDBOX_TEST_COMMAND_LOG"
grep -F '<-e> <ANDROID_AVD_HOME=/android-state/avd>' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"
grep -F "<$test_root/android:/android-state" \
  "$AI_SANDBOX_TEST_COMMAND_LOG"
grep -F '<--label> <ai-sandbox.profile=android>' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"
if grep -E '/dev/kvm|/dev/dri|--privileged' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"; then
  echo "controller mode unexpectedly received emulator privileges" >&2
  exit 1
fi

rm -f "$AI_SANDBOX_TEST_PODMAN_STATE" "$AI_SANDBOX_TEST_COMMAND_LOG"
if AI_SANDBOX_NETWORK_MODE=bridge \
  "$ai_sandbox" start "$repo_root" --android \
  >"$test_root/bridge.out" 2>"$test_root/bridge.err"; then
  echo "Android controller mode unexpectedly accepted bridge networking" >&2
  exit 1
fi
grep -F 'Android modes require host networking' "$test_root/bridge.err"
[[ ! -s "$AI_SANDBOX_TEST_COMMAND_LOG" ]]

rm -f "$AI_SANDBOX_TEST_PODMAN_STATE" "$AI_SANDBOX_TEST_COMMAND_LOG"
if [[ ! -e /dev/kvm ]]; then
  if "$ai_sandbox" start "$repo_root" --emulator \
    >"$test_root/no-kvm.out" 2>"$test_root/no-kvm.err"; then
    echo "emulator mode unexpectedly started without KVM" >&2
    exit 1
  fi
  grep -F 'requires /dev/kvm' "$test_root/no-kvm.err"
  [[ ! -e "$AI_SANDBOX_TEST_COMMAND_LOG" ]]
else
  echo "KVM is available; missing-KVM assertion skipped."
fi

rm -f "$AI_SANDBOX_TEST_PODMAN_STATE" "$AI_SANDBOX_TEST_COMMAND_LOG"
"$ai_sandbox" android-doctor "$repo_root" --android-emulator >"$test_root/doctor.out"
grep -F '<-e> <AI_SANDBOX_MODE=android-doctor>' \
  "$AI_SANDBOX_TEST_COMMAND_LOG"
grep -F '<-e> <AI_SANDBOX_ANDROID_MODE=1>' "$AI_SANDBOX_TEST_COMMAND_LOG"
grep -F '<--network> <host>' "$AI_SANDBOX_TEST_COMMAND_LOG"

if [[ ! -e /dev/kvm ]]; then
  grep -F '<-e> <AI_SANDBOX_EMULATOR_MODE=1>' "$AI_SANDBOX_TEST_COMMAND_LOG"
  if grep -F '<--device=/dev/kvm>' "$AI_SANDBOX_TEST_COMMAND_LOG"; then
    echo "diagnostic unexpectedly passed unavailable KVM" >&2
    exit 1
  fi
else
  grep -F '<--device=/dev/kvm>' "$AI_SANDBOX_TEST_COMMAND_LOG"
fi

echo "ai-sandbox Android CLI tests passed"
