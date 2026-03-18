#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/sandbox-home}"
export USER="${USER:-sandbox}"
export NIX_CONFIG="experimental-features = nix-command flakes"
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

mode="${AI_SANDBOX_MODE:-start}"
workspace="/workspace"
flake_input="${AI_SANDBOX_FLAKE:-}"
theme="${AI_SANDBOX_THEME:-light}"

mkdir -p "$HOME" "$HOME/.vscode-data" "$HOME/.vscode-extensions" "$HOME/.config/Code/User"

seed_nix_if_needed() {
  if command -v nix >/dev/null 2>&1; then
    return
  fi

  mkdir -p /nix

  if [[ ! -e /nix/store ]]; then
    rsync -a /nix-seed/ /nix/
  fi

  mkdir -p \
    /nix/var/nix/db \
    /nix/var/nix/gcroots \
    /nix/var/nix/profiles \
    /nix/var/nix/temproots \
    /nix/var/nix/userpool

  hash -r
}

ensure_default_vscode_settings() {
  local settings="$HOME/.config/Code/User/settings.json"
  if [[ -e "$settings" ]]; then
    return
  fi

  local color_theme="Default Light Modern"
  if [[ "$theme" == "dark" ]]; then
    color_theme="Default Dark Modern"
  fi

  cat > "$settings" <<EOF
{
  "workbench.colorTheme": "$color_theme",
  "window.autoDetectColorScheme": false
}
EOF
}

seed_nix_if_needed
ensure_default_vscode_settings

if ! command -v nix >/dev/null 2>&1; then
  echo "nix still not found after seeding. PATH=$PATH" >&2
  exit 1
fi

resolve_flake_target() {
  if [[ -n "$flake_input" ]]; then
    if [[ -d "$flake_input" ]]; then
      echo "$flake_input"
      return
    fi
    if [[ -f "$flake_input" ]]; then
      dirname "$flake_input"
      return
    fi
    echo "Invalid --flake path inside container: $flake_input" >&2
    exit 1
  fi

  if [[ -f "$workspace/flake.nix" ]]; then
    echo "$workspace"
    return
  fi

  echo ""
}

launch_code() {
  local target="$1"

  exec bash -lc '
    code \
      --verbose \
      --user-data-dir "$HOME/.vscode-data" \
      --extensions-dir "$HOME/.vscode-extensions" \
      "$1"
  ' _ "$target"
}

flake_target="$(resolve_flake_target)"

cd "$workspace"

case "$mode" in
  warm)
    if [[ -n "$flake_target" ]]; then
      exec nix develop "$flake_target" --command true
    else
      echo "No flake found; nothing to warm."
      exit 0
    fi
    ;;
  shell)
    if [[ -n "$flake_target" ]]; then
      exec nix develop "$flake_target"
    else
      exec bash
    fi
    ;;
  start)
    if [[ -n "$flake_target" ]]; then
      exec nix develop "$flake_target" --command \
        bash -lc '
          code \
            --verbose \
            --user-data-dir "$HOME/.vscode-data" \
            --extensions-dir "$HOME/.vscode-extensions" \
            "$1"
        ' _ "$workspace"
    else
      launch_code "$workspace"
    fi
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    exit 1
    ;;
esac