#!/usr/bin/env bash

AI_SANDBOX_MCP_IMPLEMENTATION="winx-code-agent"
AI_SANDBOX_MCP_VERSION="v0.2.351"
AI_SANDBOX_MCP_TUNNEL_VERSION="v0.0.14"
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
  printf '%s/.ai-sandbox/mcp-winx/%s\n' "$HOME_STORAGE" "$1"
}

mcp_runtime_container_dir() {
  printf '/sandbox-home\n'
}

mcp_container_id() {
  podman inspect -f '{{.Id}}' "$1" 2>/dev/null || true
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
  local runtime_api_key="$4"
  local legacy_container="$5"
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

  echo "Preparing Winx MCP server..." >&2
  podman exec "$container" \
    /usr/local/bin/ai-sandbox-mcp-install \
    "$AI_SANDBOX_MCP_VERSION" >&2
  echo "Preparing Secure MCP Tunnel client..." >&2
  podman exec "$container" \
    /usr/local/bin/ai-sandbox-mcp-tunnel-install \
    "$AI_SANDBOX_MCP_TUNNEL_VERSION" >&2
  if container_is_running "$legacy_container"; then
    echo "Stopping legacy MCP container $legacy_container..." >&2
    podman stop "$legacy_container" >/dev/null
  fi
  echo "Connecting Secure MCP Tunnel..." >&2
  CONTROL_PLANE_API_KEY="$runtime_api_key" \
    podman exec -e CONTROL_PLANE_API_KEY "$container" \
    /usr/local/bin/ai-sandbox-mcp-tunnel-start \
    "$runtime_container_dir" \
    "$AI_SANDBOX_MCP_TUNNEL_VERSION" \
    "$tunnel_id" \
    "$AI_SANDBOX_MCP_VERSION" >&2
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
  local runtime_dir runtime_container_dir metadata mode health tunnel_json tunnel_ui
  runtime_dir="$(mcp_runtime_host_dir "$hash")"
  runtime_container_dir="$(mcp_runtime_container_dir "$hash")"
  metadata="$runtime_dir/runtime/metadata.json"
  mode="$(mcp_read_metadata_field "$metadata" mode)"
  tunnel_json="$(mcp_tunnel_status_json \
    "$container" "$runtime_dir" "$runtime_container_dir")"
  health=stopped
  if [[ "$(jq -r '.ready' <<<"$tunnel_json")" == true ]]; then
    health=ok
  elif [[ "$(jq -r '.process_running' <<<"$tunnel_json")" == true ]]; then
    health=unhealthy
  fi

  if [[ "$json_output" -eq 1 ]]; then
    jq -n \
      --arg workspace "$workspace_path" \
      --arg container "$container" \
      --arg mode "$mode" \
      --arg implementation "$AI_SANDBOX_MCP_IMPLEMENTATION" \
      --arg version "$AI_SANDBOX_MCP_VERSION" \
      --arg transport "stdio" \
      --arg health "$health" \
      --argjson tunnel "$tunnel_json" \
      '{workspace: $workspace, container: $container, mode: ($mode | if length > 0 then . else null end), implementation: $implementation, version: $version, transport: $transport, endpoint: null, health: $health, tunnel: $tunnel}'
    return
  fi

  echo "AI Sandbox MCP"
  echo
  echo "Workspace: $workspace_path"
  echo "Container: $container"
  echo "Mode: ${mode:-unknown}"
  echo "Implementation: $AI_SANDBOX_MCP_IMPLEMENTATION @ $AI_SANDBOX_MCP_VERSION"
  echo "Transport: stdio through Secure MCP Tunnel"
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
  if container_is_running "$container"; then
    echo "Shell sessions: ais mcp --sessions"
  fi
}

mcp_stop_process() {
  local container="$1"
  local hash="$2"
  local quiet="${3:-0}"
  local runtime_dir tunnel_stop_failed=0
  runtime_dir="$(mcp_runtime_host_dir "$hash")"

  mcp_stop_tunnel "$container" "$hash" "$quiet" || tunnel_stop_failed=1
  [[ "$tunnel_stop_failed" -eq 0 ]] || return 1
  if container_is_running "$container"; then
    podman stop "$container" >/dev/null
    [[ "$quiet" -eq 1 ]] || echo "Stopped MCP container $container."
  fi
  rm -f "$runtime_dir/runtime/metadata.json"
}

mcp_foreground_is_healthy() {
  local container="$1"
  local runtime_dir="$2"
  local runtime_container_dir="$3"
  local tunnel_json

  tunnel_json="$(mcp_tunnel_status_json \
    "$container" "$runtime_dir" "$runtime_container_dir")"
  if [[ "$(jq -r '.process_running and .healthy and .ready' <<<"$tunnel_json")" != true ]]; then
    echo "Secure MCP Tunnel stopped unexpectedly." >&2
    return 1
  fi
}

mcp_show_shell_output() {
  local container="$1"
  local consumer="$2"
  local binary="/sandbox-home/.local/share/ai-sandbox/mcp/winx/$AI_SANDBOX_MCP_VERSION/winx-code-agent"
  local sessions session_id

  # Winx starts its daemon when the first shell session is initialized.
  sessions="$(podman exec "$container" "$binary" list 2>/dev/null)" || return 0
  sessions="$(jq -r '.[].thread_id' <<<"$sessions")" || return 1
  while IFS= read -r session_id; do
    [[ -n "$session_id" ]] || continue
    podman exec "$container" "$binary" \
      attach "$session_id" --consumer "$consumer" >&2 || return 1
  done <<<"$sessions"
}

mcp_supervise_tunnel() {
  local container="$1"
  local hash="$2"
  local runtime_dir runtime_container_dir
  local activity_pid="" stop_signal="" result=0 key=""
  local consumer="ais-foreground-$BASHPID"
  runtime_dir="$(mcp_runtime_host_dir "$hash")"
  runtime_container_dir="$(mcp_runtime_container_dir "$hash")"

  touch "$runtime_dir/runtime/usage.jsonl"
  chmod 0600 "$runtime_dir/runtime/usage.jsonl"
  trap 'stop_signal=INT' INT
  trap 'stop_signal=TERM' TERM
  trap 'stop_signal=HUP' HUP

  echo >&2
  if [[ -t 0 && -t 2 ]]; then
    echo "Winx output hidden. Press v to show Winx output; press v again to hide it." >&2
  else
    echo "Winx output hidden. Use ais mcp --sessions to inspect shell sessions." >&2
  fi
  echo "Press Ctrl-C to stop MCP and the Secure Tunnel." >&2
  while [[ -z "$stop_signal" ]]; do
    key=""
    if [[ -t 0 && -t 2 ]]; then
      IFS= read -rsn1 -t 1 key || true
      if [[ "$key" == v ]]; then
        if [[ -n "$activity_pid" ]]; then
          kill "$activity_pid" 2>/dev/null || true
          wait "$activity_pid" 2>/dev/null || true
          activity_pid=""
          echo "Winx output hidden. Press v to show it again." >&2
        else
          bash "$MCP_LIB_DIR/activity.sh" \
            "$runtime_dir/runtime/usage.jsonl" </dev/null >&2 &
          activity_pid=$!
          echo "Winx output visible. Press v to hide it." >&2
          echo "Watching for Winx shell sessions..." >&2
        fi
      fi
    else
      sleep 1 &
      wait "$!" || true
    fi
    [[ -z "$stop_signal" ]] || break

    if [[ -n "$activity_pid" ]]; then
      if ! kill -0 "$activity_pid" 2>/dev/null; then
        echo "Winx activity viewer stopped unexpectedly." >&2
        activity_pid=""
      elif ! mcp_show_shell_output "$container" "$consumer"; then
        echo "Could not read Winx shell output." >&2
      fi
    fi
    if ! mcp_foreground_is_healthy \
      "$container" "$runtime_dir" "$runtime_container_dir"; then
      result=1
      break
    fi
  done

  trap - INT TERM HUP
  if [[ -n "$activity_pid" ]]; then
    kill "$activity_pid" 2>/dev/null || true
    wait "$activity_pid" 2>/dev/null || true
  fi
  echo "Stopping MCP and Secure Tunnel..." >&2
  if ! mcp_stop_process "$container" "$hash" 1; then
    result=1
  fi

  case "$stop_signal" in
    INT) return 130 ;;
    TERM) return 143 ;;
    HUP) return 129 ;;
    *) return "$result" ;;
  esac
}

mcp_write_metadata() {
  local path="$1"
  local container_id="$2"
  local mode="$3"
  local tmp_path="$path.tmp.$$"
  mkdir -p "$(dirname "$path")"
  jq -n \
    --arg container_id "$container_id" \
    --arg mode "$mode" \
    --arg implementation "$AI_SANDBOX_MCP_IMPLEMENTATION" \
    --arg version "$AI_SANDBOX_MCP_VERSION" \
    '{container_id: $container_id, mode: $mode, implementation: $implementation, version: $version, transport: "stdio"}' >"$tmp_path"
  mv "$tmp_path" "$path"
}
