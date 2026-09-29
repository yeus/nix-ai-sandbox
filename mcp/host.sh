#!/usr/bin/env bash

AI_SANDBOX_MCP_IMPLEMENTATION="winx-code-agent"
AI_SANDBOX_MCP_VERSION="v0.2.351"
AI_SANDBOX_MCP_TUNNEL_VERSION="v0.0.14"
AI_SANDBOX_MCP_CLOUDFLARED_VERSION="2026.9.3"
AI_SANDBOX_MCP_HTTP_PORT="18081"
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

mcp_secret_workspace_dir() {
  printf '%s/mcp/%s\n' "$SECRETS_STORAGE" "$1"
}

mcp_prepare_secret_dir() {
  local hash="$1"
  local dir
  [[ "$SECRETS_STORAGE" == /* && "$SECRETS_STORAGE" != / ]] || {
    echo "AI_SANDBOX_SECRETS_STORAGE must be an absolute non-root path." >&2
    return 1
  }
  if [[ -L "$SECRETS_STORAGE" ]]; then
    echo "Refusing symlinked AI Sandbox secrets directory: $SECRETS_STORAGE" >&2
    return 1
  fi
  umask 077
  mkdir -p "$SECRETS_STORAGE/mcp"
  dir="$(mcp_secret_workspace_dir "$hash")"
  if [[ -L "$SECRETS_STORAGE/mcp" || -L "$dir" ]]; then
    echo "Refusing symlinked MCP secrets directory." >&2
    return 1
  fi
  mkdir -p "$dir"
  chmod 0700 "$SECRETS_STORAGE" "$SECRETS_STORAGE/mcp" "$dir"
  if [[ "$(stat -c %u "$dir")" != "$(id -u)" ]]; then
    echo "MCP secrets directory is not owned by the current user: $dir" >&2
    return 1
  fi
}

mcp_read_connection_name() {
  local hash="$1"
  local file
  file="$(mcp_secret_workspace_dir "$hash")/connection-name"
  [[ -f "$file" && ! -L "$file" ]] || return 0
  printf '%s\n' "$(<"$file")"
}

mcp_resolve_connection_name() {
  local hash="$1"
  local requested="$2"
  local -n resolved_name="$3"
  local root dir file registry_lock counter_file counter max_attempts=1000 candidate existing
  local other other_name registry_fd attempt in_use

  mcp_prepare_secret_dir "$hash"
  root="$SECRETS_STORAGE/mcp"
  dir="$(mcp_secret_workspace_dir "$hash")"
  file="$dir/connection-name"
  registry_lock="$root/.registry.lock"
  counter_file="$root/.next-connection-id"

  [[ ! -L "$file" && ! -L "$registry_lock" && ! -L "$counter_file" ]] || {
    echo "Refusing symlinked MCP connection registry state." >&2
    return 1
  }

  exec {registry_fd}>"$registry_lock"
  chmod 0600 "$registry_lock"
  if ! flock -w 2 "$registry_fd"; then
    echo "Another MCP connection registration is already in progress." >&2
    exec {registry_fd}>&-
    return 1
  fi

  existing=""
  [[ ! -f "$file" ]] || existing="$(<"$file")"
  if [[ -n "$existing" ]]; then
    if [[ -n "$requested" && "$requested" != "$existing" ]]; then
      echo "This workspace is already registered as '$existing'; refusing to rename it to '$requested'." >&2
      flock -u "$registry_fd"
      exec {registry_fd}>&-
      return 1
    fi
    resolved_name="$existing"
    flock -u "$registry_fd"
    exec {registry_fd}>&-
    return 0
  fi

  candidate="$requested"
  if [[ -z "$candidate" ]]; then
    counter=1
    if [[ -f "$counter_file" ]]; then
      counter="$(<"$counter_file")"
      [[ "$counter" =~ ^[1-9][0-9]*$ ]] || {
        echo "Invalid MCP connection registry counter: $counter_file" >&2
        flock -u "$registry_fd"
        exec {registry_fd}>&-
        return 1
      }
    fi
    for ((attempt = 0; attempt < max_attempts; attempt++)); do
      candidate="mcp$counter"
      counter=$((counter + 1))
      in_use=0
      for other in "$root"/*/connection-name; do
        [[ -f "$other" && ! -L "$other" ]] || continue
        other_name="$(<"$other")"
        if [[ "$other_name" == "$candidate" ]]; then
          in_use=1
          break
        fi
      done
      [[ "$in_use" -eq 1 ]] || break
      candidate=""
    done
    [[ -n "$candidate" ]] || {
      echo "Could not allocate a unique MCP connection name." >&2
      flock -u "$registry_fd"
      exec {registry_fd}>&-
      return 1
    }
    printf '%s\n' "$counter" >"$counter_file.tmp.$$"
    chmod 0600 "$counter_file.tmp.$$"
    mv "$counter_file.tmp.$$" "$counter_file"
  fi

  [[ "$candidate" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$ ]] || {
    echo "Invalid MCP connection name '$candidate' (expected 1-32 letters, digits, ., _, or -)." >&2
    flock -u "$registry_fd"
    exec {registry_fd}>&-
    return 1
  }

  for other in "$root"/*/connection-name; do
    [[ -f "$other" && ! -L "$other" ]] || continue
    [[ "$other" == "$file" ]] && continue
    other_name="$(<"$other")"
    if [[ "$other_name" == "$candidate" ]]; then
      echo "MCP connection name '$candidate' is already assigned to another workspace." >&2
      flock -u "$registry_fd"
      exec {registry_fd}>&-
      return 1
    fi
  done

  printf '%s\n' "$candidate" >"$file.tmp.$$"
  chmod 0600 "$file.tmp.$$"
  mv "$file.tmp.$$" "$file"
  resolved_name="$candidate"

  flock -u "$registry_fd"
  exec {registry_fd}>&-
}


mcp_resolve_http_token() {
  local hash="$1"
  local -n resolved_token="$2"
  local dir file temporary
  mcp_prepare_secret_dir "$hash"
  dir="$(mcp_secret_workspace_dir "$hash")"
  file="$dir/bearer-token"
  if [[ -L "$file" ]]; then
    echo "Refusing symlinked MCP bearer-token file: $file" >&2
    return 1
  fi
  if [[ ! -f "$file" ]]; then
    temporary="$dir/.bearer-token.$$"
    dd if=/dev/urandom bs=32 count=1 status=none |
      od -An -tx1 | tr -d ' \n' >"$temporary"
    printf '\n' >>"$temporary"
    chmod 0600 "$temporary"
    mv "$temporary" "$file"
  fi
  chmod 0600 "$file"
  resolved_token="$(<"$file")"
  if [[ ${#resolved_token} -lt 64 ]]; then
    echo "Stored MCP bearer token is unexpectedly short: $file" >&2
    return 1
  fi
}

mcp_print_http_token() {
  local hash="$1"
  local token
  mcp_resolve_http_token "$hash" token
  printf '%s\n' "$token"
}

mcp_resolve_cloudflare_named_config() {
  local hash="$1"
  local requested_url="$2"
  local -n resolved_token="$3"
  local -n resolved_url="$4"
  local dir token_file url_file connection

  mcp_prepare_secret_dir "$hash"
  dir="$(mcp_secret_workspace_dir "$hash")"
  token_file="$dir/cloudflare-tunnel-token"
  connection="$(mcp_read_connection_name "$hash")"
  url_file="$dir/cloudflare-public-url"
  [[ ! -L "$token_file" && ! -L "$url_file" ]] || {
    echo "Refusing symlinked Cloudflare MCP configuration." >&2
    return 1
  }
  if [[ -e "$token_file" ]]; then
    [[ -f "$token_file" && "$(stat -c %u "$token_file")" == "$(id -u)" ]] || {
      echo "Cloudflare tunnel token must be a user-owned regular file." >&2
      return 1
    }
    chmod 0600 "$token_file"
  fi
  if [[ -e "$url_file" ]]; then
    [[ -f "$url_file" && "$(stat -c %u "$url_file")" == "$(id -u)" ]] || {
      echo "Cloudflare public URL state must be a user-owned regular file." >&2
      return 1
    }
    chmod 0600 "$url_file"
  fi

  resolved_token=""
  resolved_url=""
  [[ ! -f "$token_file" ]] || resolved_token="$(<"$token_file")"
  [[ ! -f "$url_file" ]] || resolved_url="$(<"$url_file")"
  [[ -z "$requested_url" ]] || resolved_url="${requested_url%/}"

  if [[ -z "$resolved_token" ]]; then
    if [[ ! -t 0 || ! -t 2 ]]; then
      echo "Cloudflare named tunnel setup needs an interactive terminal once." >&2
      echo "Run the same command interactively and paste its tunnel token." >&2
      return 1
    fi
    read -r -s -p "Cloudflare tunnel token: " resolved_token
    echo >&2
  fi
  if [[ -z "$resolved_url" ]]; then
    if [[ ! -t 0 || ! -t 2 ]]; then
      echo "Cloudflare named tunnel setup needs its public HTTPS URL." >&2
      return 1
    fi
    read -r -p "Cloudflare public base URL for ${connection:-this MCP} (https://${connection:-mcp}.example.com): " resolved_url
    resolved_url="${resolved_url%/}"
  fi
  [[ -n "$resolved_token" ]] || {
    echo "Cloudflare tunnel token cannot be empty." >&2
    return 1
  }
  [[ "$resolved_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || {
    echo "Invalid Cloudflare public URL: expected https://host with no path." >&2
    return 1
  }

  printf '%s\n' "$resolved_token" >"$token_file"
  printf '%s\n' "$resolved_url" >"$url_file"
  chmod 0600 "$token_file" "$url_file"
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
  local hash="$1"
  local reuse_emulator="$2"
  if [[ "$reuse_emulator" -eq 1 ]]; then
    printf '/sandbox-home/.ai-sandbox/mcp-winx/%s\n' "$hash"
  else
    printf '/sandbox-home\n'
  fi
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
  runtime_container_dir="$(mcp_runtime_container_dir "$hash" "$mcp_reuse_emulator")"
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
    podman exec -e CONTROL_PLANE_API_KEY \
      -e "AI_SANDBOX_MCP_RUNTIME_DIR=$runtime_container_dir" "$container" \
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
  runtime_container_dir="$(mcp_runtime_container_dir "$hash" "$mcp_reuse_emulator")"
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

mcp_http_status_json() {
  local container="$1"
  local runtime_host_dir="$2"
  local runtime_container_dir="$3"
  local metadata="$runtime_host_dir/http/metadata.json"

  if [[ ! -f "$metadata" ]]; then
    jq -n '{configured: false, process_running: false}'
    return
  fi
  if container_is_running "$container"; then
    podman exec "$container" \
      /usr/local/bin/ai-sandbox-mcp-http-status \
      "$runtime_container_dir" 2>/dev/null && return
  fi
  jq '. + {configured: true, process_running: false}' "$metadata"
}

mcp_start_http() {
  local container="$1"
  local hash="$2"
  local token="$3"
  local bind_host="$4"
  local allowed_host="$5"
  local runtime_container_dir
  runtime_container_dir="$(mcp_runtime_container_dir "$hash" "$mcp_reuse_emulator")"

  echo "Preparing Winx MCP HTTP server..." >&2
  podman exec "$container" \
    /usr/local/bin/ai-sandbox-mcp-install \
    "$AI_SANDBOX_MCP_VERSION" >&2
  printf '%s\n' "$token" |
    podman exec -i \
      -e "AI_SANDBOX_MCP_RUNTIME_DIR=$runtime_container_dir" "$container" \
      /usr/local/bin/ai-sandbox-mcp-http-start \
      "$runtime_container_dir" "$AI_SANDBOX_MCP_VERSION" \
      "$bind_host" "$AI_SANDBOX_MCP_HTTP_PORT" "$allowed_host" >&2
}

mcp_stop_http() {
  local container="$1"
  local hash="$2"
  local runtime_container_dir
  runtime_container_dir="$(mcp_runtime_container_dir "$hash" "$mcp_reuse_emulator")"
  container_is_running "$container" || return 0
  podman exec "$container" \
    /usr/local/bin/ai-sandbox-mcp-http-stop \
    "$runtime_container_dir" >/dev/null 2>&1 || true
}

mcp_cloudflare_status_json() {
  local container="$1"
  local runtime_host_dir="$2"
  local runtime_container_dir="$3"
  local metadata="$runtime_host_dir/publish/metadata.json"

  if [[ ! -f "$metadata" ]]; then
    jq -n '{configured: false, process_running: false}'
    return
  fi
  if container_is_running "$container"; then
    podman exec "$container" \
      /usr/local/bin/ai-sandbox-mcp-cloudflare-status \
      "$runtime_container_dir" 2>/dev/null && return
  fi
  jq '. + {configured: true, process_running: false}' "$metadata"
}

mcp_prepare_cloudflare() {
  local container="$1"
  podman exec "$container" \
    /usr/local/bin/ai-sandbox-mcp-cloudflare-install \
    "$AI_SANDBOX_MCP_CLOUDFLARED_VERSION" >&2
}

mcp_start_cloudflare() {
  local container="$1"
  local hash="$2"
  local mode="$3"
  local public_url="$4"
  local tunnel_token="$5"
  local runtime_container_dir origin_url
  runtime_container_dir="$(mcp_runtime_container_dir "$hash" "$mcp_reuse_emulator")"
  origin_url="http://127.0.0.1:$AI_SANDBOX_MCP_HTTP_PORT"

  mcp_prepare_cloudflare "$container"
  if [[ "$mode" == named ]]; then
    printf '%s\n' "$tunnel_token" |
      podman exec -i "$container" \
        /usr/local/bin/ai-sandbox-mcp-cloudflare-start \
        "$runtime_container_dir" "$AI_SANDBOX_MCP_CLOUDFLARED_VERSION" \
        named "$origin_url" "$public_url" >&2
  else
    podman exec "$container" \
      /usr/local/bin/ai-sandbox-mcp-cloudflare-start \
      "$runtime_container_dir" "$AI_SANDBOX_MCP_CLOUDFLARED_VERSION" \
      quick "$origin_url" >&2
  fi
}

mcp_stop_cloudflare() {
  local container="$1"
  local hash="$2"
  local runtime_container_dir
  runtime_container_dir="$(mcp_runtime_container_dir "$hash" "$mcp_reuse_emulator")"
  container_is_running "$container" || return 0
  podman exec "$container" \
    /usr/local/bin/ai-sandbox-mcp-cloudflare-stop \
    "$runtime_container_dir" >/dev/null 2>&1 || true
}

mcp_public_host() {
  local url="$1"
  url="${url#https://}"
  printf '%s\n' "${url%%/*}"
}


mcp_emit_status() {
  local workspace_path="$1"
  local container="$2"
  local hash="$3"
  local json_output="$4"
  local runtime_dir runtime_container_dir metadata mode profile transport publisher
  local health endpoint host_port public_url connection tunnel_json tunnel_ui http_json publish_json
  runtime_dir="$(mcp_runtime_host_dir "$hash")"
  runtime_container_dir="$(mcp_runtime_container_dir "$hash" "$mcp_reuse_emulator")"
  metadata="$runtime_dir/runtime/metadata.json"
  mode="$(mcp_read_metadata_field "$metadata" mode)"
  profile="$(mcp_read_metadata_field "$metadata" profile)"
  transport="$(mcp_read_metadata_field "$metadata" transport)"
  publisher="$(mcp_read_metadata_field "$metadata" publisher)"
  host_port="$(mcp_read_metadata_field "$metadata" host_port)"
  public_url="$(mcp_read_metadata_field "$metadata" public_url)"
  connection="$(mcp_read_connection_name "$hash")"

  if [[ "$transport" == streamable-http ]]; then
    http_json="$(mcp_http_status_json "$container" "$runtime_dir" "$runtime_container_dir")"
    publish_json="$(mcp_cloudflare_status_json "$container" "$runtime_dir" "$runtime_container_dir")"
    [[ -z "$public_url" ]] || public_url="${public_url%/}"
    if [[ -n "$publisher" ]]; then
      [[ -n "$public_url" ]] || public_url="$(jq -r '.public_url // empty' <<<"$publish_json")"
      endpoint="${public_url%/}/mcp"
    else
      endpoint="http://127.0.0.1:$host_port/mcp"
    fi

    health=stopped
    if [[ "$(jq -r '.process_running' <<<"$http_json")" == true ]]; then
      if [[ -z "$publisher" || "$(jq -r '.process_running' <<<"$publish_json")" == true ]]; then
        health=ok
      else
        health=unhealthy
      fi
    elif [[ "$(jq -r '.process_running' <<<"$publish_json")" == true ]]; then
      health=unhealthy
    fi

    if [[ "$json_output" -eq 1 ]]; then
      jq -n \
        --arg workspace "$workspace_path" \
        --arg connection "$connection" \
        --arg container "$container" \
        --arg mode "$mode" \
        --arg profile "$profile" \
        --argjson reuse_emulator "${mcp_reuse_emulator:-0}" \
        --arg implementation "$AI_SANDBOX_MCP_IMPLEMENTATION" \
        --arg version "$AI_SANDBOX_MCP_VERSION" \
        --arg endpoint "$endpoint" \
        --arg health "$health" \
        --arg publisher "$publisher" \
        --argjson http "$http_json" \
        --argjson publish "$publish_json" \
        '{
          workspace: $workspace,
          connection: ($connection | if length > 0 then . else null end),
          container: $container,
          profile: ($profile | if length > 0 then . else null end),
          reuse_emulator: ($reuse_emulator == 1),
          mode: ($mode | if length > 0 then . else null end),
          implementation: $implementation,
          version: $version,
          transport: "streamable-http",
          endpoint: $endpoint,
          auth: "bearer",
          publisher: ($publisher | if length > 0 then . else null end),
          health: $health,
          http: $http,
          publish: $publish
        }'
      return
    fi

    echo "AI Sandbox MCP"
    echo
    echo "Workspace: $workspace_path"
    [[ -z "$connection" ]] || echo "Connection: $connection"
    echo "Container: $container"
    [[ -z "$profile" ]] || echo "Profile: $profile"
    echo "Mode: ${mode:-unknown}"
    echo "Implementation: $AI_SANDBOX_MCP_IMPLEMENTATION @ $AI_SANDBOX_MCP_VERSION"
    echo "Transport: Streamable HTTP"
    echo "Endpoint: $endpoint"
    echo "Authentication: bearer token"
    case "$publisher" in
      cloudflare) echo "Publisher: Cloudflare named tunnel" ;;
      cloudflare-quick) echo "Publisher: Cloudflare Quick Tunnel" ;;
      "") ;;
    esac
    case "$health" in
      ok) echo "Health: OK" ;;
      *) echo "Health: ${health^^}" ;;
    esac
    echo "API key: ais mcp --show-key"
    container_is_running "$container" && echo "Shell sessions: ais mcp --sessions"
    return
  fi

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
      --arg connection "$connection" \
      --arg container "$container" \
      --arg mode "$mode" \
      --arg profile "$profile" \
      --argjson reuse_emulator "${mcp_reuse_emulator:-0}" \
      --arg implementation "$AI_SANDBOX_MCP_IMPLEMENTATION" \
      --arg version "$AI_SANDBOX_MCP_VERSION" \
      --arg health "$health" \
      --argjson tunnel "$tunnel_json" \
      '{workspace: $workspace, connection: ($connection | if length > 0 then . else null end), container: $container, profile: ($profile | if length > 0 then . else null end), reuse_emulator: ($reuse_emulator == 1), mode: ($mode | if length > 0 then . else null end), implementation: $implementation, version: $version, transport: "stdio", endpoint: null, health: $health, tunnel: $tunnel}'
    return
  fi

  echo "AI Sandbox MCP"
  echo
  echo "Workspace: $workspace_path"
  [[ -z "$connection" ]] || echo "Connection: $connection"
  echo "Container: $container"
  [[ -z "$profile" ]] || echo "Profile: $profile"
  [[ "${mcp_reuse_emulator:-0}" -eq 0 ]] || echo "Reusing emulator container: yes"
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
  container_is_running "$container" && echo "Shell sessions: ais mcp --sessions"
}

mcp_stop_process() {
  local container="$1"
  local hash="$2"
  local quiet="${3:-0}"
  local runtime_dir tunnel_stop_failed=0
  runtime_dir="$(mcp_runtime_host_dir "$hash")"

  mcp_stop_cloudflare "$container" "$hash"
  mcp_stop_http "$container" "$hash"
  mcp_stop_tunnel "$container" "$hash" "$quiet" || tunnel_stop_failed=1
  [[ "$tunnel_stop_failed" -eq 0 ]] || return 1
  if [[ "${mcp_reuse_emulator:-0}" -eq 0 ]] && container_is_running "$container"; then
    podman stop "$container" >/dev/null
    [[ "$quiet" -eq 1 ]] || echo "Stopped MCP container $container."
  fi
  rm -f \
    "$runtime_dir/runtime/metadata.json" \
    "$runtime_dir/http/metadata.json" \
    "$runtime_dir/publish/metadata.json"
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
  runtime_container_dir="$(mcp_runtime_container_dir "$hash" "$mcp_reuse_emulator")"

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
  local container="$4"
  local reuse_emulator="$5"
  local profile="$6"
  local transport="$7"
  local publisher="${8:-}"
  local host_port="${9:-}"
  local public_url="${10:-}"
  local tmp_path="$path.tmp.$$"
  mkdir -p "$(dirname "$path")"
  jq -n \
    --arg container_id "$container_id" \
    --arg container "$container" \
    --arg profile "$profile" \
    --argjson reuse_emulator "$reuse_emulator" \
    --arg mode "$mode" \
    --arg implementation "$AI_SANDBOX_MCP_IMPLEMENTATION" \
    --arg version "$AI_SANDBOX_MCP_VERSION" \
    --arg transport "$transport" \
    --arg publisher "$publisher" \
    --arg host_port "$host_port" \
    --arg public_url "$public_url" \
    '{
      container_id: $container_id,
      container: $container,
      profile: $profile,
      reuse_emulator: ($reuse_emulator == 1),
      mode: $mode,
      implementation: $implementation,
      version: $version,
      transport: $transport,
      publisher: ($publisher | if length > 0 then . else null end),
      host_port: ($host_port | if length > 0 then . else null end),
      public_url: ($public_url | if length > 0 then . else null end)
    }' >"$tmp_path"
  mv "$tmp_path" "$path"
}
