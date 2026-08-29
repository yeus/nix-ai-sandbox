#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ai_sandbox="$repo_root/ai-sandbox/ai-sandbox"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

export AI_SANDBOX_STATE_DIR="$test_root/state"
export AI_SANDBOX_HOME_STORAGE="$test_root/home"
export AI_SANDBOX_NIX_STORAGE="$test_root/nix"
export AI_SANDBOX_TEST_COMMAND_LOG="$test_root/commands.log"
export AI_SANDBOX_TEST_BUILD_STATUS=42

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

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
  "build --no-cache")
    exit "${AI_SANDBOX_TEST_BUILD_STATUS:-0}"
    ;;
  "rmi -f")
    echo "rebuild removed an image" >&2
    exit 1
    ;;
esac

exit 0
EOF

chmod +x "$fake_bin/podman"
export PATH="$fake_bin:/usr/bin:/bin"

if "$ai_sandbox" rebuild >"$test_root/failure.out" 2>"$test_root/failure.err"; then
  echo "failed rebuild unexpectedly succeeded" >&2
  exit 1
fi
grep -F 'without removing existing containers' "$test_root/failure.out"
grep -F '<--no-cache>' "$AI_SANDBOX_TEST_COMMAND_LOG"
if grep -F '<rmi>' "$AI_SANDBOX_TEST_COMMAND_LOG"; then
  echo "failed rebuild attempted to remove the old image" >&2
  exit 1
fi

: >"$AI_SANDBOX_TEST_COMMAND_LOG"
export AI_SANDBOX_TEST_BUILD_STATUS=0
"$ai_sandbox" rebuild >"$test_root/success.out"
grep -F '<--no-cache>' "$AI_SANDBOX_TEST_COMMAND_LOG"
if grep -F '<rmi>' "$AI_SANDBOX_TEST_COMMAND_LOG"; then
  echo "successful rebuild attempted to remove the old image" >&2
  exit 1
fi

echo "ai-sandbox rebuild safety tests passed"
