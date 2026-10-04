#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ai_sandbox="$repo_root/ai-sandbox/ai-sandbox"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/workspace"
export AI_SANDBOX_STATE_DIR="$test_root/state"
export AI_SANDBOX_HOME_STORAGE="$test_root/home"
export AI_SANDBOX_NIX_STORAGE="$test_root/nix"
export AI_SANDBOX_TMP_ROOT="$test_root/host-tmp"
export AI_SANDBOX_TEST_COMMAND_LOG="$test_root/commands.log"
export XDG_DATA_HOME="$test_root/data"
export XDG_CONFIG_HOME="$test_root/config"
export PATH="$test_root/bin:/usr/bin:/bin"

cat >"$test_root/bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'podman' >>"$AI_SANDBOX_TEST_COMMAND_LOG"
printf ' <%s>' "$@" >>"$AI_SANDBOX_TEST_COMMAND_LOG"
printf '\n' >>"$AI_SANDBOX_TEST_COMMAND_LOG"
case "${1:-} ${2:-}" in
  'image exists') exit 0 ;;
  'run --rm') exit 0 ;;
esac
exit 0
EOF
chmod +x "$test_root/bin/podman"

"$ai_sandbox" shell "$test_root/workspace" \
  --instance first -- true >/dev/null
first_dir="$(find "$AI_SANDBOX_TMP_ROOT" \
  -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$first_dir" ]]
[[ "$(stat -c %a "$AI_SANDBOX_TMP_ROOT")" == 700 ]]
[[ "$(stat -c %a "$first_dir")" == 1777 ]]
grep -qF "<$first_dir:/tmp" "$AI_SANDBOX_TEST_COMMAND_LOG"
# Local-time software must inherit the host timezone on container creation.
grep -qF '<--tz=local>' "$AI_SANDBOX_TEST_COMMAND_LOG"

"$ai_sandbox" shell "$test_root/workspace" \
  --instance second -- true >/dev/null
[[ "$(find "$AI_SANDBOX_TMP_ROOT" \
  -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]]

mv "$AI_SANDBOX_TMP_ROOT" "$test_root/saved-tmp"
ln -s "$test_root/saved-tmp" "$AI_SANDBOX_TMP_ROOT"
if "$ai_sandbox" shell "$test_root/workspace" \
  --instance third -- true >"$test_root/unsafe.out" \
  2>"$test_root/unsafe.err"; then
  echo 'Sandbox accepted a symlinked host temp root' >&2
  exit 1
fi
grep -F 'Refusing unsafe host temp root' \
  "$test_root/unsafe.err"

echo 'ai-sandbox host temp mount tests passed'
