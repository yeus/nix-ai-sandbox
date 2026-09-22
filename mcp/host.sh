#!/usr/bin/env bash

AI_SANDBOX_MCP_IMPLEMENTATION="gpt-repo-mcp"
AI_SANDBOX_MCP_COMMIT="986f2135f00959f8e0d214ed8d173a7054f4cea1"
AI_SANDBOX_MCP_TUNNEL_VERSION="v0.0.14"
AI_SANDBOX_MCP_PORT_MIN=19080
AI_SANDBOX_MCP_PORT_COUNT=920
AI_SANDBOX_MCP_TUNNELS_URL="https://platform.openai.com/settings/organization/tunnels"
AI_SANDBOX_MCP_RUNTIME_KEYS_URL="https://platform.openai.com/settings/organization/api-keys"

mcp_secret_lookup() {
  local field="$1"
  secret-tool lookup \
    service ai-sandbox \
    credential "$field" 2>/dev/null || true
}

mcp_secret_store() {
  local field="$1"
  local label="$2"
  local value="$3"
  if ! printf '%s' "$value" | secret-tool store \
    --label="$label" \
    service ai-sandbox \
    credential "$field" >/dev/null; then
    echo "Could not store $label in Secret Service." >&2
    return 1
  fi
}

mcp_explain_missing_tunnel_credentials() {
  local tunnel_id="$1"
  local runtime_key="$2"
  if [[ -z "$tunnel_id" ]]; then
    echo "Create an OpenAI Secure MCP Tunnel, then copy its tunnel ID:" >&2
    echo "  $AI_SANDBOX_MCP_TUNNELS_URL" >&2
  fi
  if [[ -z "$runtime_key" ]]; then
    echo "Create a runtime API key with Tunnels Read + Use, then copy it:" >&2
    echo "  $AI_SANDBOX_MCP_RUNTIME_KEYS_URL" >&2
  fi
}

mcp_resolve_tunnel_credentials() {
  local requested_tunnel_id="$1"
  local -n resolved_tunnel_id="$2"
  local -n resolved_runtime_key="$3"
  local saved_tunnel_id saved_runtime_key

  if ! command -v secret-tool >/dev/null 2>&1; then
    echo "Secure MCP Tunnel setup requires Secret Service (secret-tool)." >&2
    echo "Install libsecret, then retry." >&2
    return 1
  fi

  saved_tunnel_id="$(mcp_secret_lookup tunnel-id)"
  saved_runtime_key="$(mcp_secret_lookup runtime-api-key)"
  resolved_tunnel_id="${requested_tunnel_id:-$saved_tunnel_id}"
  resolved_runtime_key="$saved_runtime_key"

  mcp_explain_missing_tunnel_credentials \
    "$resolved_tunnel_id" "$resolved_runtime_key"
  if { [[ -z "$resolved_tunnel_id" ]] || [[ -z "$resolved_runtime_key" ]]; } &&
    { [[ ! -t 0 ]] || [[ ! -t 2 ]]; }; then
    echo "Tunnel setup needs an interactive terminal to securely collect missing values." >&2
    return 1
  fi

  if [[ -z "$resolved_tunnel_id" ]]; then
    read -r -p "Tunnel ID: " resolved_tunnel_id
  fi
  if [[ ! "$resolved_tunnel_id" =~ ^tunnel_[a-z0-9]{32}$ ]]; then
    echo "Invalid tunnel ID: expected tunnel_<32 lowercase letters or digits>." >&2
    return 1
  fi
  if [[ -z "$resolved_runtime_key" ]]; then
    read -r -s -p "Runtime API key: " resolved_runtime_key
    echo >&2
    if [[ -z "$resolved_runtime_key" ]]; then
      echo "Runtime API key cannot be empty." >&2
      return 1
    fi
  fi
}

mcp_store_tunnel_credentials() {
  local tunnel_id="$1"
  local runtime_key="$2"
  local saved_tunnel_id saved_runtime_key
  saved_tunnel_id="$(mcp_secret_lookup tunnel-id)"
  saved_runtime_key="$(mcp_secret_lookup runtime-api-key)"

  if [[ "$tunnel_id" != "$saved_tunnel_id" ]]; then
    mcp_secret_store tunnel-id "AI Sandbox MCP tunnel ID" "$tunnel_id"
  fi
  if [[ "$runtime_key" != "$saved_runtime_key" ]]; then
    mcp_secret_store \
      runtime-api-key \
      "AI Sandbox MCP runtime API key" \
      "$runtime_key"
  fi
}

mcp_require_home_path() {
  if [[ "$HOME_STORAGE" != /* ]]; then
    echo "ai-sandbox mcp requires AI_SANDBOX_HOME_STORAGE to be an absolute host path." >&2
    echo "Named Podman home volumes cannot provide the isolated MCP runtime mount." >&2
    return 1
  fi
}

mcp_runtime_host_dir() {
  printf '%s/.ai-sandbox/mcp/%s\n' "$HOME_STORAGE" "$1"
}

mcp_runtime_container_dir() {
  printf '/sandbox-home/.ai-sandbox/mcp/%s\n' "$1"
}

mcp_port_assigned_elsewhere() {
  local requested="$1"
  local own_file="$2"
  local file

  [[ -d "$HOME_STORAGE/.ai-sandbox/mcp" ]] || return 1
  for file in "$HOME_STORAGE"/.ai-sandbox/mcp/*/port; do
    [[ -f "$file" && "$file" != "$own_file" ]] || continue
    [[ "$(<"$file")" == "$requested" ]] && return 0
  done
  return 1
}

mcp_resolve_port() {
  local hash="$1"
  local requested="$2"
  local runtime_dir assignment stored candidate start offset probe
  runtime_dir="$(mcp_runtime_host_dir "$hash")"
  assignment="$runtime_dir/port"
  stored=""
  [[ -f "$assignment" ]] && stored="$(<"$assignment")"

  if [[ -n "$requested" ]]; then
    candidate="$requested"
  elif [[ -n "$stored" ]]; then
    candidate="$stored"
  else
    start=$((AI_SANDBOX_MCP_PORT_MIN + 16#${hash:0:6} % AI_SANDBOX_MCP_PORT_COUNT))
    candidate=""
    for ((offset = 0; offset < AI_SANDBOX_MCP_PORT_COUNT; offset++)); do
      probe=$((AI_SANDBOX_MCP_PORT_MIN + (start - AI_SANDBOX_MCP_PORT_MIN + offset) % AI_SANDBOX_MCP_PORT_COUNT))
      if ! mcp_port_assigned_elsewhere "$probe" "$assignment" && ! port_is_listening "$probe"; then
        candidate="$probe"
        break
      fi
    done
    [[ -n "$candidate" ]] || {
      echo "No free MCP port found in 19080-19999." >&2
      return 1
    }
  fi

  if mcp_port_assigned_elsewhere "$candidate" "$assignment"; then
    echo "MCP port $candidate is assigned to another workspace." >&2
    return 1
  fi
  if port_is_listening "$candidate"; then
    echo "MCP port $candidate is already in use." >&2
    return 1
  fi

  mkdir -p "$runtime_dir"
  printf '%s\n' "$candidate" >"$assignment"
  printf '%s\n' "$candidate"
}

mcp_write_config() {
  local hash="$1"
  local mode="$2"
  local config_path tmp_path
  config_path="$(mcp_runtime_host_dir "$hash")/config.json"
  tmp_path="$config_path.tmp.$$"
  mkdir -p "$(dirname "$config_path")"

  case "$mode" in
    read)
      jq -n '{repos: [{repo_id: "workspace", display_name: "workspace", root: "/workspace", writes: {enabled: false}, operations: {enabled: false}}], limits: {}}' >"$tmp_path"
      ;;
    write)
      jq -n '{repos: [{repo_id: "workspace", display_name: "workspace", root: "/workspace", writes: {enabled: true, allowed_globs: ["**"]}, operations: {enabled: false}}], limits: {}}' >"$tmp_path"
      ;;
    ship)
      jq -n '{repos: [{repo_id: "workspace", display_name: "workspace", root: "/workspace", writes: {enabled: true, allowed_globs: ["**"]}, operations: {enabled: true, git_stage_enabled: true, git_commit_enabled: true, validation_enabled: true, validation_test_path_globs: ["tests/**", "**/*.test.ts", "**/*.spec.ts"], cleanup_enabled: true}}], limits: {}}' >"$tmp_path"
      ;;
    *)
      echo "Unknown MCP permission mode: $mode" >&2
      return 1
      ;;
  esac
  mv "$tmp_path" "$config_path"
}

mcp_container_id() {
  podman inspect -f '{{.Id}}' "$1" 2>/dev/null || true
}

mcp_process_state() {
  local container="$1"
  local runtime_container_dir="$2"
  local expected_container_id="$3"
  local current_container_id

  current_container_id="$(mcp_container_id "$container")"
  if [[ -z "$current_container_id" ]]; then
    if [[ -n "$expected_container_id" ]]; then
      printf 'stale\n'
    else
      printf 'stopped\n'
    fi
    return
  fi
  if [[ -n "$expected_container_id" && "$current_container_id" != "$expected_container_id" ]]; then
    printf 'stale\n'
    return
  fi
  if ! container_is_running "$container"; then
    printf 'stopped\n'
    return
  fi
  podman exec "$container" /usr/local/bin/ai-sandbox-mcp-status "$runtime_container_dir" 2>/dev/null || printf 'stale\n'
}

mcp_health_state() {
  local process_state="$1"
  local port="$2"
  if [[ "$process_state" != running ]]; then
    printf '%s\n' "$process_state"
    return
  fi
  if curl -fsS --max-time 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
    printf 'ok\n'
  else
    printf 'unhealthy\n'
  fi
}

mcp_read_metadata_field() {
  local metadata="$1"
  local field="$2"
  [[ -f "$metadata" ]] || return 0
  jq -r --arg field "$field" '.[$field] // empty' "$metadata" 2>/dev/null || true
}

mcp_tunnel_status_json() {
  local container="$1"
  local runtime_host_dir="$2"
  local runtime_container_dir="$3"
  local metadata="$runtime_host_dir/tunnel/metadata.json"
  local version

  if [[ ! -f "$metadata" ]]; then
    jq -n '{configured: false, process_running: false, healthy: false, ready: false}'
    return
  fi
  version="$(mcp_read_metadata_field "$metadata" version)"
  [[ -n "$version" ]] || version="$AI_SANDBOX_MCP_TUNNEL_VERSION"
  if container_is_running "$container"; then
    podman exec "$container" \
      /usr/local/bin/ai-sandbox-mcp-tunnel-status \
      "$runtime_container_dir" \
      "$version" 2>/dev/null && return
  fi
  jq '. + {configured: true, process_running: false, healthy: false, ready: false}' \
    "$metadata"
}

mcp_start_tunnel() {
  local container="$1"
  local hash="$2"
  local tunnel_id="$3"
  local port="$4"
  local runtime_api_key="$5"
  local runtime_dir runtime_container_dir tunnel_json existing_tunnel_id
  runtime_dir="$(mcp_runtime_host_dir "$hash")"
  runtime_container_dir="$(mcp_runtime_container_dir "$hash")"
  tunnel_json="$(mcp_tunnel_status_json \
    "$container" "$runtime_dir" "$runtime_container_dir")"

  if [[ "$(jq -r '.process_running' <<<"$tunnel_json")" == true ]]; then
    existing_tunnel_id="$(jq -r '.tunnel_id // empty' <<<"$tunnel_json")"
    if [[ "$existing_tunnel_id" == "$tunnel_id" ]]; then
      echo "Secure MCP Tunnel is already running for this workspace." >&2
      return 0
    fi
    echo "Secure MCP Tunnel is already running with $existing_tunnel_id." >&2
    echo "Stop it before changing tunnels." >&2
    return 1
  fi

  echo "Preparing Secure MCP Tunnel client..." >&2
  podman exec "$container" \
    /usr/local/bin/ai-sandbox-mcp-tunnel-install \
    "$AI_SANDBOX_MCP_TUNNEL_VERSION" >&2
  echo "Connecting Secure MCP Tunnel..." >&2
  CONTROL_PLANE_API_KEY="$runtime_api_key" \
    podman exec -e CONTROL_PLANE_API_KEY "$container" \
    /usr/local/bin/ai-sandbox-mcp-tunnel-start \
    "$runtime_container_dir" \
    "$AI_SANDBOX_MCP_TUNNEL_VERSION" \
    "$tunnel_id" \
    "$port" >&2
}

mcp_stop_tunnel() {
  local container="$1"
  local hash="$2"
  local quiet="${3:-0}"
  local runtime_dir runtime_container_dir tunnel_json tunnel_version attempt
  runtime_dir="$(mcp_runtime_host_dir "$hash")"
  runtime_container_dir="$(mcp_runtime_container_dir "$hash")"
  tunnel_json="$(mcp_tunnel_status_json \
    "$container" "$runtime_dir" "$runtime_container_dir")"

  if [[ "$(jq -r '.configured' <<<"$tunnel_json")" != true ]] ||
    [[ "$(jq -r '.process_running' <<<"$tunnel_json")" != true ]] ||
    ! container_is_running "$container"; then
    return 0
  fi
  tunnel_version="$(jq -r '.version // empty' <<<"$tunnel_json")"
  [[ -n "$tunnel_version" ]] || tunnel_version="$AI_SANDBOX_MCP_TUNNEL_VERSION"
  podman exec "$container" \
    /usr/local/bin/ai-sandbox-mcp-tunnel-stop \
    "$runtime_container_dir" \
    "$tunnel_version"

  for ((attempt = 1; attempt <= 10; attempt++)); do
    tunnel_json="$(mcp_tunnel_status_json \
      "$container" "$runtime_dir" "$runtime_container_dir")"
    if [[ "$(jq -r '.process_running' <<<"$tunnel_json")" != true ]]; then
      [[ "$quiet" -eq 1 ]] || echo "Stopped Secure MCP Tunnel for $container."
      return 0
    fi
    sleep 0.2
  done
  echo "Secure MCP Tunnel is still running for $container." >&2
  return 1
}

mcp_emit_status() {
  local workspace_path="$1"
  local container="$2"
  local hash="$3"
  local json_output="$4"
  local runtime_dir runtime_container_dir metadata port mode pid expected_container_id process_state health endpoint tunnel_json tunnel_ui
  runtime_dir="$(mcp_runtime_host_dir "$hash")"
  runtime_container_dir="$(mcp_runtime_container_dir "$hash")"
  metadata="$runtime_dir/runtime/metadata.json"
  port="$(mcp_read_metadata_field "$metadata" port)"
  [[ -n "$port" ]] || { [[ -f "$runtime_dir/port" ]] && port="$(<"$runtime_dir/port")"; }
  mode="$(mcp_read_metadata_field "$metadata" mode)"
  pid=""
  [[ -f "$runtime_dir/runtime/pid" ]] && pid="$(<"$runtime_dir/runtime/pid")"
  expected_container_id="$(mcp_read_metadata_field "$metadata" container_id)"
  process_state="$(mcp_process_state "$container" "$runtime_container_dir" "$expected_container_id")"
  health="$(mcp_health_state "$process_state" "${port:-0}")"
  endpoint=""
  [[ -n "$port" ]] && endpoint="http://127.0.0.1:$port/mcp"
  tunnel_json="$(mcp_tunnel_status_json \
    "$container" "$runtime_dir" "$runtime_container_dir")"

  if [[ "$json_output" -eq 1 ]]; then
    jq -n \
      --arg workspace "$workspace_path" \
      --arg repository_id workspace \
      --arg container "$container" \
      --arg mode "$mode" \
      --arg implementation "$AI_SANDBOX_MCP_IMPLEMENTATION" \
      --arg version "$AI_SANDBOX_MCP_COMMIT" \
      --arg transport "local HTTP" \
      --arg endpoint "$endpoint" \
      --arg pid "$pid" \
      --arg health "$health" \
      --argjson tunnel "$tunnel_json" \
      '{workspace: $workspace, repository_id: $repository_id, container: $container, mode: ($mode | if length > 0 then . else null end), implementation: $implementation, version: $version, transport: $transport, endpoint: ($endpoint | if length > 0 then . else null end), pid: ($pid | if length > 0 then . else null end), health: $health, tunnel: $tunnel}'
    return
  fi

  echo "AI Sandbox MCP"
  echo
  echo "Workspace: $workspace_path"
  echo "Repository ID: workspace"
  echo "Container: $container"
  echo "Mode: ${mode:-unknown}"
  echo "Implementation: $AI_SANDBOX_MCP_IMPLEMENTATION @ $AI_SANDBOX_MCP_COMMIT"
  echo "Transport: local HTTP"
  echo "Endpoint: ${endpoint:-unassigned}"
  echo "PID: ${pid:-none}"
  case "$health" in
    ok) echo "Health: OK" ;;
    *) echo "Health: ${health^^}" ;;
  esac
  if [[ "$(jq -r '.configured' <<<"$tunnel_json")" == true ]]; then
    echo "Secure Tunnel: $(jq -r '.tunnel_id' <<<"$tunnel_json")"
    echo "Tunnel Client: $(jq -r '.version' <<<"$tunnel_json")"
    if [[ "$(jq -r '.ready' <<<"$tunnel_json")" == true ]]; then
      echo "Tunnel Health: READY"
    elif [[ "$(jq -r '.process_running' <<<"$tunnel_json")" == true ]]; then
      echo "Tunnel Health: UNHEALTHY"
    else
      echo "Tunnel Health: STOPPED"
    fi
    tunnel_ui="$(jq -r '.ui_url // empty' <<<"$tunnel_json")"
    [[ -z "$tunnel_ui" ]] || echo "Tunnel UI: $tunnel_ui"
  else
    echo "Secure Tunnel: disabled"
  fi
}

mcp_stop_process() {
  local container="$1"
  local hash="$2"
  local quiet="${3:-0}"
  local runtime_dir runtime_container_dir metadata expected_container_id process_state tunnel_stop_failed=0
  runtime_dir="$(mcp_runtime_host_dir "$hash")"
  runtime_container_dir="$(mcp_runtime_container_dir "$hash")"
  metadata="$runtime_dir/runtime/metadata.json"
  expected_container_id="$(mcp_read_metadata_field "$metadata" container_id)"
  process_state="$(mcp_process_state "$container" "$runtime_container_dir" "$expected_container_id")"

  mcp_stop_tunnel "$container" "$hash" "$quiet" || tunnel_stop_failed=1

  if [[ "$process_state" == running ]]; then
    podman exec "$container" /usr/local/bin/ai-sandbox-mcp-stop "$runtime_container_dir"
    [[ "$quiet" -eq 1 ]] || echo "Stopped MCP process for $container."
  else
    [[ "$quiet" -eq 1 ]] || echo "No running MCP process found for $container."
  fi
  rm -f "$runtime_dir/runtime/pid" "$metadata"
  return "$tunnel_stop_failed"
}

mcp_wait_for_pid() {
  local pid_file="$1"
  local attempt
  for ((attempt = 1; attempt <= 50; attempt++)); do
    [[ -s "$pid_file" ]] && return 0
    sleep 0.1
  done
  echo "MCP process did not record its PID." >&2
  return 1
}

mcp_wait_for_health() {
  local port="$1"
  local container="$2"
  local attempt
  for ((attempt = 1; attempt <= 80; attempt++)); do
    if curl -fsS --max-time 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      return 0
    fi
    if ! container_is_running "$container"; then
      echo "Sandbox container stopped before MCP became ready." >&2
      return 1
    fi
    sleep 0.25
  done
  echo "Timed out waiting for MCP health endpoint on 127.0.0.1:$port." >&2
  return 1
}

mcp_write_metadata() {
  local path="$1"
  local workspace_path="$2"
  local container="$3"
  local container_id="$4"
  local mode="$5"
  local port="$6"
  local pid="$7"
  local tmp_path="$path.tmp.$$"
  mkdir -p "$(dirname "$path")"
  jq -n \
    --arg workspace "$workspace_path" \
    --arg container "$container" \
    --arg container_id "$container_id" \
    --arg mode "$mode" \
    --arg implementation "$AI_SANDBOX_MCP_IMPLEMENTATION" \
    --arg version "$AI_SANDBOX_MCP_COMMIT" \
    --argjson port "$port" \
    --argjson pid "$pid" \
    '{workspace: $workspace, container: $container, container_id: $container_id, mode: $mode, implementation: $implementation, version: $version, transport: "local HTTP", port: $port, pid: $pid}' >"$tmp_path"
  mv "$tmp_path" "$path"
}

mcp_start_process() {
  local workspace_path="$1"
  local container="$2"
  local hash="$3"
  local mode="$4"
  local requested_port="$5"
  local runtime_dir runtime_container_dir metadata existing_mode existing_port expected_container_id process_state port container_id pid
  runtime_dir="$(mcp_runtime_host_dir "$hash")"
  runtime_container_dir="$(mcp_runtime_container_dir "$hash")"
  metadata="$runtime_dir/runtime/metadata.json"
  mkdir -p "$runtime_dir/runtime" "$runtime_dir/upstream-runtime"

  existing_mode="$(mcp_read_metadata_field "$metadata" mode)"
  existing_port="$(mcp_read_metadata_field "$metadata" port)"
  expected_container_id="$(mcp_read_metadata_field "$metadata" container_id)"
  process_state="$(mcp_process_state "$container" "$runtime_container_dir" "$expected_container_id")"
  if [[ "$process_state" == running ]]; then
    if [[ "$existing_mode" != "$mode" || ( -n "$requested_port" && "$existing_port" != "$requested_port" ) ]]; then
      echo "MCP is already running with mode=$existing_mode port=$existing_port." >&2
      echo "Stop it before changing mode or port." >&2
      return 1
    fi
    echo "MCP is already running for this workspace." >&2
    return
  fi
  if [[ "$process_state" == stale ]]; then
    rm -f "$runtime_dir/runtime/pid" "$metadata"
  fi

  port="$(mcp_resolve_port "$hash" "$requested_port")"
  mcp_write_config "$hash" "$mode"
  podman exec "$container" /usr/local/bin/ai-sandbox-mcp-install "$AI_SANDBOX_MCP_COMMIT" >&2
  podman exec "$container" /usr/local/bin/ai-sandbox-mcp-launch \
    "$runtime_container_dir" "$AI_SANDBOX_MCP_COMMIT" "$port" >&2
  mcp_wait_for_pid "$runtime_dir/runtime/pid"
  pid="$(<"$runtime_dir/runtime/pid")"
  container_id="$(mcp_container_id "$container")"
  mcp_write_metadata "$metadata" "$workspace_path" "$container" "$container_id" "$mode" "$port" "$pid"
  mcp_wait_for_health "$port" "$container"
}
