#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_root/mcp/tunnel-state-guard.sh"
test_root="$(mktemp -d)"
stale_pid=""
valid_pid=""
cleanup() {
  [[ -z "$stale_pid" ]] || kill "$stale_pid" 2>/dev/null || true
  [[ -z "$valid_pid" ]] || kill "$valid_pid" 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "$*" >&2
  exit 1
}

state="$test_root/state"
profiles="$test_root/profiles"
mkdir -p "$state/health" "$profiles"

# A live PID from a new container can collide with the recorded PID from the
# previous container. The guard must not trust it or signal it.
sleep 300 &
stale_pid=$!
jq -n \
  --argjson pid "$stale_pid" \
  '{workspace: {pid: $pid, profile_dir: "/tmp/unrelated-profile", profile_name: "workspace"}}' \
  >"$state/processes.yaml"
printf 'stale\n' >"$state/health/workspace.url"

bash "$guard" "$state" workspace \
  >"$test_root/stale.out" 2>"$test_root/stale.err" ||
  fail "Guard failed on stale runtime state"
kill -0 "$stale_pid" 2>/dev/null ||
  fail "Guard killed an unrelated process with the stale PID"
[[ ! -e "$state/processes.yaml" ]] ||
  fail "Guard kept stale tunnel process state"
[[ ! -e "$state/health/workspace.url" ]] ||
  fail "Guard kept the stale tunnel health URL"
grep -q 'Cleared stale Secure MCP Tunnel runtime state' "$test_root/stale.err" ||
  fail "Guard did not report stale state cleanup"

# A matching live tunnel-client process must be preserved.
bash -c 'exec -a tunnel-client python3 -c "import time; time.sleep(300)" run --profile-dir "$1" --profile workspace' \
  _ "$profiles" &
valid_pid=$!
for _ in {1..50}; do
  [[ -r "/proc/$valid_pid/cmdline" ]] && break
  sleep 0.05
done
printf 'live\n' >"$state/health/workspace.url"
jq -n \
  --argjson pid "$valid_pid" \
  --arg profile_dir "$profiles" \
  '{workspace: {pid: $pid, profile_dir: $profile_dir, profile_name: "workspace"}}' \
  >"$state/processes.yaml"

bash "$guard" "$state" workspace \
  >"$test_root/valid.out" 2>"$test_root/valid.err" ||
  fail "Guard failed on live runtime state"
kill -0 "$valid_pid" 2>/dev/null ||
  fail "Guard stopped a live tunnel-client process"
[[ -f "$state/processes.yaml" ]] ||
  fail "Guard removed live tunnel process state"
[[ -f "$state/health/workspace.url" ]] ||
  fail "Guard removed the live tunnel health URL"
[[ ! -s "$test_root/valid.err" ]] ||
  fail "Guard reported cleanup for live runtime state"

# A missing runtime file is a no-op.
rm -f "$state/processes.yaml"
bash "$guard" "$state" workspace \
  >"$test_root/missing.out" 2>"$test_root/missing.err" ||
  fail "Guard failed without runtime state"
[[ ! -s "$test_root/missing.err" ]] ||
  fail "Guard reported an error without runtime state"

echo "MCP tunnel runtime state guard checks passed"
