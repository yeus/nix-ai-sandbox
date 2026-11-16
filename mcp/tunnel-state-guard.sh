#!/usr/bin/env bash
set -euo pipefail

# The tunnel state directory lives in the shared sandbox home, but tunnel-client
# records a PID that is only meaningful inside the container that started it.
# After a container restart the same PID can belong to an unrelated process, so
# only trust it when /proc shows the expected tunnel-client command.
state_dir="${1:?tunnel state directory is required}"
alias="${2:?tunnel alias is required}"
processes="$state_dir/processes.yaml"
health_url="$state_dir/health/$alias.url"

[[ "$alias" =~ ^[A-Za-z0-9_-]+$ ]] || {
  echo "Invalid tunnel alias: $alias" >&2
  exit 1
}
[[ ! -L "$processes" ]] || {
  echo "Refusing symlinked tunnel runtime state: $processes" >&2
  exit 1
}
[[ -f "$processes" ]] || exit 0

pid="$(jq -r --arg alias "$alias" '.[$alias].pid // empty' "$processes" 2>/dev/null || true)"
profile_dir="$(jq -r --arg alias "$alias" '.[$alias].profile_dir // empty' "$processes" 2>/dev/null || true)"
profile_name="$(jq -r --arg alias "$alias" '.[$alias].profile_name // empty' "$processes" 2>/dev/null || true)"

runtime_is_live() {
  local pid="$1"
  local profile_dir="$2"
  local profile_name="$3"
  local -a args
  local index has_profile_dir=0 has_profile_name=0

  [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || return 1
  mapfile -d '' -t args <"/proc/$pid/cmdline" || return 1
  (( ${#args[@]} > 1 )) || return 1
  [[ "$(basename -- "${args[0]}")" == tunnel-client ]] || return 1

  for ((index = 1; index < ${#args[@]} - 1; index++)); do
    [[ "${args[index]}" != --profile-dir ]] || {
      [[ "${args[index + 1]}" != "$profile_dir" ]] || has_profile_dir=1
    }
    [[ "${args[index]}" != --profile ]] || {
      [[ "${args[index + 1]}" != "$profile_name" ]] || has_profile_name=1
    }
  done
  [[ "$has_profile_dir" -eq 1 && "$has_profile_name" -eq 1 ]]
}

runtime_is_live "$pid" "$profile_dir" "$profile_name" && exit 0

rm -f -- "$processes"
[[ -L "$state_dir/health" ]] || rm -f -- "$health_url"
echo "Cleared stale Secure MCP Tunnel runtime state for alias $alias." >&2
