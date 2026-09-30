#!/usr/bin/env bash
# Host-side MCP slot gateway helpers. Sourced by ai-sandbox after mcp/host.sh.
#
# The gateway is a host-level reverse proxy bound to 127.0.0.1. It routes
# /slot/<N>/<capability>/mcp to the loopback port of the workspace assigned to
# slot N and injects that workspace's internal bearer token. Slot identity is
# stable: stopping a workspace never reassigns its slot, and the workspace can
# never choose another slot from the public tool interface.

AI_SANDBOX_MCP_GATEWAY_DEFAULT_SLOTS=5
AI_SANDBOX_MCP_GATEWAY_PORT=18082

mcp_gateway_root_dir() {
  printf '%s/mcp/gateway\n' "$SECRETS_STORAGE"
}

mcp_gateway_registry_file() {
  printf '%s/registry.json\n' "$(mcp_gateway_root_dir)"
}

mcp_gateway_tokens_dir() {
  printf '%s/tokens\n' "$(mcp_gateway_root_dir)"
}

mcp_gateway_lock_file() {
  printf '%s/.lock\n' "$(mcp_gateway_root_dir)"
}

mcp_gateway_state_dir() {
  printf '%s/mcp-gateway\n' "$STATE_DIR"
}

mcp_gateway_pid_file() {
  printf '%s/gateway.pid\n' "$(mcp_gateway_state_dir)"
}

mcp_gateway_publish_pid_file() {
  printf '%s/cloudflared.pid\n' "$(mcp_gateway_state_dir)"
}

mcp_gateway_binary() {
  if [[ -n "${AI_SANDBOX_MCP_GATEWAY_BIN:-}" ]]; then
    printf '%s\n' "$AI_SANDBOX_MCP_GATEWAY_BIN"
    return 0
  fi
  command -v ai-sandbox-mcp-gateway 2>/dev/null || true
}

mcp_gateway_prepare() {
  local root tokens
  mcp_prepare_secret_dir gateway
  root="$(mcp_gateway_root_dir)"
  tokens="$(mcp_gateway_tokens_dir)"
  [[ ! -L "$root" && ! -L "$tokens" ]] || {
    echo "Refusing symlinked MCP gateway state." >&2
    return 1
  }
  umask 077
  mkdir -p "$tokens"
  chmod 0700 "$root" "$tokens"
  [[ "$(stat -c %u "$tokens")" == "$(id -u)" ]] || {
    echo "MCP gateway token directory is not owned by the current user: $tokens" >&2
    return 1
  }
}

mcp_gateway_registry_read() {
  local file
  file="$(mcp_gateway_registry_file)"
  [[ -f "$file" && ! -L "$file" ]] || return 0
  jq -c . "$file" 2>/dev/null || true
}

mcp_gateway_registry_require() {
  local current
  current="$(mcp_gateway_registry_read)"
  [[ -n "$current" ]] || {
    echo "MCP gateway is not configured. Run 'ais mcp gateway setup' first." >&2
    return 1
  }
  printf '%s\n' "$current"
}

mcp_gateway_mutate() {
  local file lock_file lock_fd current tmp jq_err
  mcp_gateway_prepare
  file="$(mcp_gateway_registry_file)"
  lock_file="$(mcp_gateway_lock_file)"
  [[ ! -L "$file" && ! -L "$lock_file" ]] || {
    echo "Refusing symlinked MCP gateway registry state." >&2
    return 1
  }
  exec {lock_fd}>"$lock_file"
  chmod 0600 "$lock_file"
  if ! flock -w 3 "$lock_fd"; then
    echo "Another MCP gateway registry update is already in progress." >&2
    exec {lock_fd}>&-
    return 1
  fi

  current="$(mcp_gateway_registry_read)"
  [[ -n "$current" ]] ||
    current='{"version":1,"size":0,"auth":"capability","port":'"$AI_SANDBOX_MCP_GATEWAY_PORT"',"public_url":null,"slots":{}}'
  tmp="$file.tmp.$$"
  jq_err="$tmp.err"
  if ! jq -c "$@" <<<"$current" >"$tmp" 2>"$jq_err"; then
    [[ ! -s "$jq_err" ]] || cat "$jq_err" >&2
    rm -f -- "$tmp" "$jq_err"
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    echo "Could not update the MCP gateway registry." >&2
    return 1
  fi
  rm -f -- "$jq_err"
  chmod 0600 "$tmp"
  mv "$tmp" "$file"
  flock -u "$lock_fd"
  exec {lock_fd}>&-
}

mcp_gateway_ensure_tokens() {
  local size="$1"
  local tokens n file value tmp
  mcp_gateway_prepare
  tokens="$(mcp_gateway_tokens_dir)"
  for ((n = 1; n <= size; n++)); do
    file="$tokens/$n"
    [[ ! -L "$file" ]] || {
      echo "Refusing symlinked MCP gateway token: $file" >&2
      return 1
    }
    if [[ -e "$file" ]]; then
      [[ -f "$file" && "$(stat -c %u "$file")" == "$(id -u)" ]] || {
        echo "MCP gateway token must be a user-owned regular file: $file" >&2
        return 1
      }
      chmod 0600 "$file"
      value="$(<"$file")"
      [[ "$value" =~ ^[a-f0-9]{64}$ ]] || {
        echo "Invalid MCP gateway token state: $file" >&2
        return 1
      }
      continue
    fi
    tmp="$file.tmp.$$"
    dd if=/dev/urandom bs=32 count=1 status=none |
      od -An -tx1 | tr -d ' \n' >"$tmp"
    chmod 0600 "$tmp"
    mv "$tmp" "$file"
  done
}

mcp_gateway_slot_token() {
  local slot="$1" file
  file="$(mcp_gateway_tokens_dir)/$slot"
  [[ -f "$file" && ! -L "$file" ]] || return 0
  printf '%s\n' "$(<"$file")"
}

mcp_gateway_setup() {
  local size="${1:-$AI_SANDBOX_MCP_GATEWAY_DEFAULT_SLOTS}"
  local current
  [[ "$size" =~ ^[1-9][0-9]?$ ]] || {
    echo "Invalid slot count: $size (expected 1-99)." >&2
    return 1
  }
  current="$(mcp_gateway_registry_read)"
  if [[ -z "$current" ]]; then
    mcp_gateway_mutate \
      --argjson size "$size" \
      --argjson port "$AI_SANDBOX_MCP_GATEWAY_PORT" \
      '{version: 1, size: $size, auth: "capability", port: $port, public_url: null, slots: {}}'
  else
    # The shrink check runs inside the lock so a concurrent assignment cannot
    # add a slot above the new pool size between the check and the update.
    if ! mcp_gateway_mutate --argjson size "$size" '
      ([.slots | keys[] | tonumber] | max // 0) as $max |
      if $size < $max then
        error("slot pool size \($size) is below the highest assigned slot \($max); release that slot before shrinking the pool")
      else .size = $size end
    '; then
      return 1
    fi
    size="$(jq -r '.size' <<<"$(mcp_gateway_registry_require)")"
  fi
  mcp_gateway_ensure_tokens "$size"
  echo "MCP gateway configured with $size slots."
  echo "Start it with: ais mcp gateway start"
}

mcp_gateway_slot_owner() {
  local slot="$1" current
  current="$(mcp_gateway_registry_read)"
  [[ -n "$current" ]] || return 0
  jq -r --arg slot "$slot" '.slots[$slot].workspace_hash // empty' <<<"$current"
}

mcp_gateway_slot_workspace() {
  local slot="$1" current
  current="$(mcp_gateway_registry_read)"
  [[ -n "$current" ]] || return 0
  jq -r --arg slot "$slot" '.slots[$slot].workspace // empty' <<<"$current"
}

mcp_gateway_slot_for_hash() {
  local hash="$1" current
  current="$(mcp_gateway_registry_read)"
  [[ -n "$current" ]] || return 0
  jq -r --arg hash "$hash" \
    '[.slots | to_entries[] | select(.value.workspace_hash == $hash) | .key] | first // empty' \
    <<<"$current"
}

mcp_gateway_assign() {
  local hash="$1"
  local workspace="$2"
  local connection="$3"
  local slot="$4"
  local takeover="${5:-0}"
  local file lock_file lock_fd current size owner other now tmp

  [[ "$slot" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid slot number: $slot" >&2
    return 1
  }
  mcp_gateway_prepare
  file="$(mcp_gateway_registry_file)"
  lock_file="$(mcp_gateway_lock_file)"
  [[ ! -L "$file" && ! -L "$lock_file" ]] || {
    echo "Refusing symlinked MCP gateway registry state." >&2
    return 1
  }
  exec {lock_fd}>"$lock_file"
  chmod 0600 "$lock_file"
  if ! flock -w 3 "$lock_fd"; then
    echo "Another MCP gateway registry update is already in progress." >&2
    exec {lock_fd}>&-
    return 1
  fi

  current="$(mcp_gateway_registry_read)"
  if [[ -z "$current" ]]; then
    echo "MCP gateway is not configured. Run 'ais mcp gateway setup' first." >&2
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 1
  fi
  size="$(jq -r '.size // 0' <<<"$current")"
  if ((slot < 1 || slot > size)); then
    echo "Slot $slot is outside the configured slot pool (1-$size)." >&2
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 1
  fi
  owner="$(jq -r --arg slot "$slot" '.slots[$slot].workspace_hash // empty' <<<"$current")"
  if [[ -n "$owner" && "$owner" != "$hash" && "$takeover" -ne 1 ]]; then
    echo "Slot $slot is already assigned to another workspace." >&2
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 3
  fi
  other="$(jq -r \
    --arg hash "$hash" --arg slot "$slot" \
    '[.slots | to_entries[] | select(.value.workspace_hash == $hash and .key != $slot) | .key] | first // empty' \
    <<<"$current")"
  if [[ -n "$other" && "$takeover" -ne 1 ]]; then
    echo "This workspace is already assigned to slot $other." >&2
    echo "Use --takeover-slot to move it to slot $slot." >&2
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 4
  fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$file.tmp.$$"
  if ! jq -c \
    --arg slot "$slot" \
    --arg hash "$hash" \
    --arg workspace "$workspace" \
    --arg connection "$connection" \
    --arg other "$other" \
    --arg now "$now" \
    '
    (if $other != "" then del(.slots[$other]) else . end) |
    .slots[$slot] = {
      workspace: $workspace,
      workspace_hash: $hash,
      connection: $connection,
      assigned_at: $now
    }
    ' <<<"$current" >"$tmp"; then
    rm -f -- "$tmp"
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    echo "Could not update the MCP gateway registry." >&2
    return 1
  fi
  chmod 0600 "$tmp"
  mv "$tmp" "$file"
  flock -u "$lock_fd"
  exec {lock_fd}>&-
}

mcp_gateway_unassign() {
  local hash="$1"
  local current slot owner_after
  current="$(mcp_gateway_registry_read)"
  if [[ -z "$current" ]]; then
    echo "MCP gateway is not configured." >&2
    return 1
  fi
  slot="$(mcp_gateway_slot_for_hash "$hash")"
  if [[ -z "$slot" ]]; then
    echo "No gateway slot is assigned to this workspace."
    return 0
  fi
  # Delete conditionally inside the lock so a concurrent takeover of this slot
  # is never undone by a stale read.
  mcp_gateway_mutate \
    --arg slot "$slot" \
    --arg hash "$hash" \
    'if (.slots[$slot].workspace_hash // "") == $hash then del(.slots[$slot]) else . end' ||
    return 1
  owner_after="$(mcp_gateway_slot_owner "$slot")"
  if [[ -z "$owner_after" ]]; then
    echo "Released MCP gateway slot $slot."
  else
    echo "Slot $slot was reassigned concurrently; nothing was released." >&2
  fi
}

mcp_gateway_slot_state() {
  local hash="$1"
  local metadata transport port
  metadata="$HOME_STORAGE/.ai-sandbox/mcp-winx/$hash/runtime/metadata.json"
  transport="$(mcp_read_metadata_field "$metadata" transport)"
  port="$(mcp_read_metadata_field "$metadata" host_port)"
  if [[ "$transport" != streamable-http || -z "$port" ]]; then
    printf 'stopped\n'
    return 0
  fi
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    printf 'ready\n'
  else
    printf 'stopped\n'
  fi
}

mcp_gateway_running() {
  local pid_file pid
  pid_file="$(mcp_gateway_pid_file)"
  [[ -f "$pid_file" && ! -L "$pid_file" ]] || return 1
  pid="$(<"$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

mcp_gateway_publish_running() {
  local pid_file pid
  pid_file="$(mcp_gateway_publish_pid_file)"
  [[ -f "$pid_file" && ! -L "$pid_file" ]] || return 1
  pid="$(<"$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

mcp_gateway_public_url() {
  local file
  file="$(mcp_gateway_root_dir)/cloudflare-public-url"
  [[ -f "$file" && ! -L "$file" ]] || return 0
  printf '%s\n' "$(<"$file")"
}

mcp_gateway_status_json() {
  local current size port public_url running publish_running slots n entry state
  current="$(mcp_gateway_registry_read)"
  [[ -n "$current" ]] ||
    current='{"version":1,"size":0,"auth":"capability","port":'"$AI_SANDBOX_MCP_GATEWAY_PORT"',"public_url":null,"slots":{}}'
  size="$(jq -r '.size // 0' <<<"$current")"
  port="$(jq -r '.port // '"$AI_SANDBOX_MCP_GATEWAY_PORT"'' <<<"$current")"
  public_url="$(mcp_gateway_public_url)"
  running=false
  mcp_gateway_running && running=true
  publish_running=false
  mcp_gateway_publish_running && publish_running=true

  slots='[]'
  for ((n = 1; n <= size; n++)); do
    entry="$(jq -c --arg slot "$n" '.slots[$slot] // null' <<<"$current")"
    if [[ "$entry" == null ]]; then
      state=free
    else
      state="$(mcp_gateway_slot_state "$(jq -r '.workspace_hash' <<<"$entry")")"
    fi
    slots="$(jq -c \
      --argjson slot "$n" \
      --arg state "$state" \
      --argjson entry "$entry" \
      '. + [{
        slot: $slot,
        app: ("mcp" + ($slot | tostring)),
        path: ("/slot/" + ($slot | tostring) + "/mcp"),
        assigned: ($entry != null),
        workspace: ($entry.workspace // null),
        workspace_hash: ($entry.workspace_hash // null),
        connection: ($entry.connection // null),
        state: $state
      }]' <<<"$slots")"
  done
  jq -n \
    --argjson running "$running" \
    --argjson publish_running "$publish_running" \
    --arg bind "127.0.0.1:$port" \
    --arg auth "$(jq -r '.auth // "capability"' <<<"$current")" \
    --arg public_url "$public_url" \
    --argjson slots "$slots" \
    '{
      gateway: {
        running: $running,
        bind: $bind,
        auth: $auth,
        public_url: ($public_url | if length > 0 then . else null end),
        publishing: $publish_running
      },
      slots: $slots
    }'
}

mcp_gateway_print_status() {
  local json_flag="$1" status
  [[ -n "$(mcp_gateway_registry_read)" ]] || {
    echo "MCP gateway is not configured. Run 'ais mcp gateway setup' first." >&2
    return 1
  }
  status="$(mcp_gateway_status_json)"
  if [[ "$json_flag" -eq 1 ]]; then
    printf '%s\n' "$status"
    return 0
  fi
  local running bind auth public_url
  running="$(jq -r '.gateway.running' <<<"$status")"
  bind="$(jq -r '.gateway.bind' <<<"$status")"
  auth="$(jq -r '.gateway.auth' <<<"$status")"
  public_url="$(jq -r '.gateway.public_url // empty' <<<"$status")"
  echo "MCP gateway: $([[ "$running" == true ]] && echo running || echo stopped)"
  echo "Bind: $bind"
  echo "Auth: $auth (capability token in every slot URL)"
  if [[ -n "$public_url" ]]; then
    echo "Public base: $public_url"
  else
    echo "Public base: not configured (loopback only)"
  fi
  echo
  while IFS=$'\t' read -r slot app path assigned workspace state; do
    [[ -n "$slot" ]] || continue
    if [[ "$assigned" == true ]]; then
      printf 'Slot %-2s %-5s %s  -> %s  %s\n' \
        "$slot" "$app" "$path" "$workspace" "${state^^}"
    else
      printf 'Slot %-2s %-5s %s  -> free\n' "$slot" "$app" "$path"
    fi
  done < <(jq -r '.slots[] | [.slot, .app, .path, .assigned, (.workspace // "free"), .state] | @tsv' <<<"$status")
}

mcp_gateway_print_slots() {
  mcp_gateway_print_status "$1"
}

mcp_gateway_endpoints_json() {
  local current port public_url slot token local_url public_slot_url
  current="$(mcp_gateway_registry_read)"
  [[ -n "$current" ]] || current='{"slots":{}}'
  port="$(jq -r '.port // '"$AI_SANDBOX_MCP_GATEWAY_PORT"'' <<<"$current")"
  public_url="$(mcp_gateway_public_url)"
  local endpoints='[]'
  while IFS= read -r slot; do
    [[ -n "$slot" ]] || continue
    token="$(mcp_gateway_slot_token "$slot")"
    [[ -n "$token" ]] || continue
    local_url="http://127.0.0.1:$port/slot/$slot/$token/mcp"
    public_slot_url=""
    [[ -z "$public_url" ]] ||
      public_slot_url="${public_url%/}/slot/$slot/$token/mcp"
    endpoints="$(jq -c \
      --argjson slot "$slot" \
      --arg local_url "$local_url" \
      --arg public_url "$public_slot_url" \
      '. + [{slot: $slot, local_url: $local_url, public_url: ($public_url | if length > 0 then . else null end)}]' \
      <<<"$endpoints")"
  done < <(jq -r '.slots | keys[] | tonumber' <<<"$current" | sort -n)
  jq -n \
    --argjson endpoints "$endpoints" \
    --arg warning "Slot URLs contain capability secrets. Treat them like passwords." \
    '{endpoints: $endpoints, warning: $warning}'
}

mcp_gateway_print_endpoints() {
  local json_flag="$1" endpoints
  [[ -n "$(mcp_gateway_registry_read)" ]] || {
    echo "MCP gateway is not configured. Run 'ais mcp gateway setup' first." >&2
    return 1
  }
  endpoints="$(mcp_gateway_endpoints_json)"
  if [[ "$json_flag" -eq 1 ]]; then
    printf '%s\n' "$endpoints"
    return 0
  fi
  echo "Slot registration endpoints (capability URLs, treat them like passwords):"
  while IFS=$'\t' read -r slot local_url public_url; do
    [[ -n "$slot" ]] || continue
    echo "Slot $slot"
    echo "  local:  $local_url"
    [[ -z "$public_url" ]] || echo "  public: $public_url"
  done < <(jq -r '.endpoints[] | [.slot, .local_url, (.public_url // "")] | @tsv' <<<"$endpoints")
  echo
  echo "ChatGPT developer-mode app URLs must use the public endpoint."
  echo "Publishing without OAuth is development-only: ais mcp gateway publish cloudflare --dev-insecure"
}

mcp_gateway_start() {
  local current port bind bin state config log pid_file log_file attempt
  current="$(mcp_gateway_registry_require)" || return 1
  if mcp_gateway_running; then
    echo "MCP gateway is already running."
    return 0
  fi
  bin="$(mcp_gateway_binary)"
  [[ -n "$bin" && -x "$bin" ]] || {
    echo "MCP gateway binary not found." >&2
    echo "Install it with Home Manager or set AI_SANDBOX_MCP_GATEWAY_BIN." >&2
    return 1
  }
  mcp_gateway_prepare
  state="$(mcp_gateway_state_dir)"
  mkdir -p "$state"
  chmod 0700 "$state"
  config="$state/config.json"
  log_file="$state/gateway.log"
  port="$(jq -r '.port // '"$AI_SANDBOX_MCP_GATEWAY_PORT"'' <<<"$current")"
  bind="127.0.0.1:$port"
  umask 077
  jq -n \
    --arg bind "$bind" \
    --arg registry "$(mcp_gateway_registry_file)" \
    --arg tokens_dir "$(mcp_gateway_tokens_dir)" \
    --arg secrets_storage "$SECRETS_STORAGE" \
    --arg home_storage "$HOME_STORAGE" \
    '{bind: $bind, registry: $registry, tokens_dir: $tokens_dir, secrets_storage: $secrets_storage, home_storage: $home_storage}' \
    >"$config.tmp.$$"
  chmod 0600 "$config.tmp.$$"
  mv "$config.tmp.$$" "$config"
  : >"$log_file"
  chmod 0600 "$log_file"

  nohup "$bin" --config "$config" >"$log_file" 2>&1 </dev/null &
  pid=$!
  pid_file="$(mcp_gateway_pid_file)"
  printf '%s\n' "$pid" >"$pid_file.tmp.$$"
  chmod 0600 "$pid_file.tmp.$$"
  mv "$pid_file.tmp.$$" "$pid_file"

  for ((attempt = 1; attempt <= 50; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "MCP gateway exited during startup." >&2
      tail -40 "$log_file" >&2 || true
      rm -f "$pid_file"
      return 1
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      echo "MCP gateway started on http://$bind"
      return 0
    fi
    sleep 0.1
  done
  echo "MCP gateway did not become ready on $bind." >&2
  kill "$pid" 2>/dev/null || true
  rm -f "$pid_file"
  tail -40 "$log_file" >&2 || true
  return 1
}

mcp_gateway_stop() {
  local pid_file pid attempt
  pid_file="$(mcp_gateway_pid_file)"
  if [[ ! -f "$pid_file" ]]; then
    echo "No MCP gateway process recorded."
    return 0
  fi
  pid="$(<"$pid_file")"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for ((attempt = 1; attempt <= 50; attempt++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    echo "Stopped MCP gateway."
  else
    echo "MCP gateway was not running."
  fi
  rm -f "$pid_file"
}

mcp_gateway_resolve_publish_config() {
  local requested_url="$1"
  local -n out_token="$2"
  local -n out_url="$3"
  local token_file url_file
  mcp_gateway_prepare
  token_file="$(mcp_gateway_root_dir)/cloudflare-tunnel-token"
  url_file="$(mcp_gateway_root_dir)/cloudflare-public-url"
  [[ ! -L "$token_file" && ! -L "$url_file" ]] || {
    echo "Refusing symlinked MCP gateway Cloudflare configuration." >&2
    return 1
  }
  out_token=""
  out_url=""
  [[ ! -f "$token_file" ]] || out_token="$(<"$token_file")"
  [[ ! -f "$url_file" ]] || out_url="$(<"$url_file")"
  [[ -z "$requested_url" ]] || out_url="${requested_url%/}"

  if [[ -z "$out_token" ]]; then
    if [[ ! -t 0 || ! -t 2 ]]; then
      echo "Gateway Cloudflare publishing needs an interactive terminal once." >&2
      echo "Run the same command interactively and paste its tunnel token." >&2
      return 1
    fi
    read -r -s -p "Cloudflare tunnel token: " out_token
    echo >&2
  fi
  if [[ -z "$out_url" ]]; then
    if [[ ! -t 0 || ! -t 2 ]]; then
      echo "Gateway Cloudflare publishing needs its public HTTPS base URL." >&2
      return 1
    fi
    read -r -p "Cloudflare public base URL for the MCP gateway (https://mcp.example.com): " out_url
    out_url="${out_url%/}"
  fi
  [[ -n "$out_token" ]] || {
    echo "Cloudflare tunnel token cannot be empty." >&2
    return 1
  }
  [[ "$out_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || {
    echo "Invalid Cloudflare public URL: expected https://host with no path." >&2
    return 1
  }
  umask 077
  printf '%s\n' "$out_token" >"$token_file.tmp.$$"
  chmod 0600 "$token_file.tmp.$$"
  mv "$token_file.tmp.$$" "$token_file"
  printf '%s\n' "$out_url" >"$url_file.tmp.$$"
  chmod 0600 "$url_file.tmp.$$"
  mv "$url_file.tmp.$$" "$url_file"
}

mcp_gateway_publish_cloudflare() {
  local requested_url="$1"
  local dev_insecure="$2"
  local token url state log_file pid pid_file attempt
  if [[ "$dev_insecure" -ne 1 ]]; then
    echo "Public MCP publishing is disabled by default." >&2
    echo "The gateway can only protect public routes with capability URLs today," >&2
    echo "and ChatGPT apps cannot send static API keys or custom mTLS." >&2
    echo "OAuth 2.1 at the gateway is not implemented yet." >&2
    echo "If you accept the development-only capability-URL model, rerun with --dev-insecure." >&2
    return 1
  fi
  mcp_gateway_running || {
    echo "Start the MCP gateway first: ais mcp gateway start" >&2
    return 1
  }
  command -v cloudflared >/dev/null 2>&1 || {
    echo "cloudflared is not on PATH; install it with Home Manager first." >&2
    return 1
  }
  mcp_gateway_resolve_publish_config "$requested_url" token url
  state="$(mcp_gateway_state_dir)"
  mkdir -p "$state"
  chmod 0700 "$state"
  log_file="$state/cloudflared.log"
  pid_file="$(mcp_gateway_publish_pid_file)"
  : >"$log_file"
  chmod 0600 "$log_file"

  nohup env TUNNEL_TOKEN="$token" \
    cloudflared tunnel --no-autoupdate --loglevel info run \
    >"$log_file" 2>&1 </dev/null &
  pid=$!
  token=""
  printf '%s\n' "$pid" >"$pid_file.tmp.$$"
  chmod 0600 "$pid_file.tmp.$$"
  mv "$pid_file.tmp.$$" "$pid_file"

  for ((attempt = 1; attempt <= 80; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "Gateway cloudflared exited during startup." >&2
      tail -40 "$log_file" >&2 || true
      rm -f "$pid_file"
      return 1
    fi
    if rg -q 'Registered tunnel connection|Connection .* registered' "$log_file"; then
      echo "Gateway publisher running for $url"
      echo "WARNING: public slot URLs are capability URLs; anyone holding one can run Bash in that workspace." >&2
      echo "This is a development-only mode." >&2
      return 0
    fi
    sleep 0.25
  done
  echo "Gateway cloudflared did not become ready." >&2
  kill "$pid" 2>/dev/null || true
  rm -f "$pid_file"
  tail -40 "$log_file" >&2 || true
  return 1
}

mcp_gateway_unpublish() {
  local pid_file pid attempt
  pid_file="$(mcp_gateway_publish_pid_file)"
  if [[ ! -f "$pid_file" ]]; then
    echo "No gateway publisher is recorded."
    return 0
  fi
  pid="$(<"$pid_file")"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for ((attempt = 1; attempt <= 50; attempt++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    echo "Stopped the gateway Cloudflare publisher."
  else
    echo "The gateway Cloudflare publisher was not running."
  fi
  rm -f "$pid_file"
}

mcp_gateway_dispatch() {
  local command="$1"
  local slots_arg="$2"
  local public_url_arg="$3"
  local dev_insecure="$4"
  local json_flag="$5"
  case "$command" in
    setup) mcp_gateway_setup "${slots_arg:-$AI_SANDBOX_MCP_GATEWAY_DEFAULT_SLOTS}" ;;
    start) mcp_gateway_start ;;
    stop) mcp_gateway_stop ;;
    status) mcp_gateway_print_status "$json_flag" ;;
    endpoints) mcp_gateway_print_endpoints "$json_flag" ;;
    publish) mcp_gateway_publish_cloudflare "$public_url_arg" "$dev_insecure" ;;
    unpublish) mcp_gateway_unpublish ;;
    *)
      echo "Unknown mcp gateway subcommand: ${command:-<missing>}" >&2
      echo "Use setup, start, stop, status, endpoints, publish, or unpublish." >&2
      return 1
      ;;
  esac
}
