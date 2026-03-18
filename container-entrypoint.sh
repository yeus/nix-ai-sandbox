#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/sandbox-home}"
export USER="${USER:-sandbox}"
export NIX_CONFIG="experimental-features = nix-command flakes"
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

mode="${AI_SANDBOX_MODE:-start}"
workspace="/workspace"
flake_input="${AI_SANDBOX_FLAKE:-}"

mkdir -p "$HOME" "$HOME/.vscode-data" "$HOME/.vscode-extensions"

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

seed_nix_if_needed

if ! command -v nix >/dev/null 2>&1; then
  echo "nix still not found after seeding. PATH=$PATH" >&2
  echo "--- /usr/local/bin/nix ---" >&2
  ls -l /usr/local/bin/nix >&2 || true
  echo "--- resolved nix target ---" >&2
  readlink -f /usr/local/bin/nix >&2 || true
  echo "--- /nix/store head ---" >&2
  ls -la /nix/store | head >&2 || true
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
        code \
          --user-data-dir "$HOME/.vscode-data" \
          --extensions-dir "$HOME/.vscode-extensions" \
          "$workspace"
    else
      exec code \
        --user-data-dir "$HOME/.vscode-data" \
        --extensions-dir "$HOME/.vscode-extensions" \
        "$workspace"
    fi
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    exit 1
    ;;
esac