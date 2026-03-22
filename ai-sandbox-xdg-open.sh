#!/usr/bin/env bash
set -euo pipefail

url="${1:-}"
if [[ -z "$url" ]]; then
  echo "Missing URL for xdg-open wrapper" >&2
  exit 1
fi

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  echo "DBUS_SESSION_BUS_ADDRESS is not set; cannot reach host portal." >&2
  exit 1
fi

urldecode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

map_host_path_to_container() {
  local input_path="$1"
  local host_root="${AI_SANDBOX_HOST_MOUNT_ROOT:-}"
  local container_root="${AI_SANDBOX_CONTAINER_MOUNT_ROOT:-/workspace}"

  if [[ -z "$host_root" ]]; then
    return 1
  fi

  if [[ "$input_path" == "$host_root" ]]; then
    printf '%s\n' "$container_root"
    return 0
  fi

  if [[ "$input_path" == "$host_root/"* ]]; then
    printf '%s/%s\n' "$container_root" "${input_path#"$host_root"/}"
    return 0
  fi

  return 1
}

open_in_sandbox_code_if_file_target() {
  local target="$1"
  local candidate="$target"
  local path_part line_part col_part mapped_path goto_target

  # file:///path/... links are commonly used by editor launchers.
  if [[ "$candidate" == file://* ]]; then
    candidate="$(urldecode "${candidate#file://}")"
  fi

  # Not a local path target; keep host-portal behavior for real URLs.
  if [[ "$candidate" != /* ]]; then
    return 1
  fi

  path_part="$candidate"
  line_part=""
  col_part=""

  # Parse optional :line[:column] suffix.
  if [[ "$candidate" =~ ^(.+):([0-9]+):([0-9]+)$ ]]; then
    path_part="${BASH_REMATCH[1]}"
    line_part="${BASH_REMATCH[2]}"
    col_part="${BASH_REMATCH[3]}"
  elif [[ "$candidate" =~ ^(.+):([0-9]+)$ ]]; then
    path_part="${BASH_REMATCH[1]}"
    line_part="${BASH_REMATCH[2]}"
  fi

  mapped_path="$path_part"
  if [[ ! -e "$mapped_path" ]]; then
    if ! mapped_path="$(map_host_path_to_container "$path_part")"; then
      return 1
    fi
  fi

  if [[ ! -e "$mapped_path" ]]; then
    return 1
  fi

  goto_target="$mapped_path"
  if [[ -n "$line_part" && -n "$col_part" ]]; then
    goto_target="${goto_target}:${line_part}:${col_part}"
  elif [[ -n "$line_part" ]]; then
    goto_target="${goto_target}:${line_part}"
  fi

  exec code \
    --user-data-dir "${AI_SANDBOX_VSCODE_USER_DATA_DIR:-$HOME/.vscode-data}" \
    --extensions-dir "${AI_SANDBOX_VSCODE_EXTENSIONS_DIR:-$HOME/.vscode-extensions}" \
    --goto "$goto_target"
}

open_in_sandbox_code_if_file_target "$url"

# Prefer desktop portal to open non-file targets in the host browser.
# Parent window is empty string because we are in a containerized X11 app.
exec gdbus call \
  --session \
  --dest org.freedesktop.portal.Desktop \
  --object-path /org/freedesktop/portal/desktop \
  --method org.freedesktop.portal.OpenURI.OpenURI \
  "" \
  "$url" \
  "{}"
