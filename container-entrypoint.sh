#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/sandbox-home}"
export USER="${USER:-sandbox}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"
export NIX_CONFIG="experimental-features = nix-command flakes"
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

mode="${AI_SANDBOX_MODE:-start}"
workspace="${AI_SANDBOX_WORKSPACE:-/workspace}"
flake_input="${AI_SANDBOX_FLAKE:-}"
theme="${AI_SANDBOX_THEME:-light}"
vscode_user_data_dir="${AI_SANDBOX_VSCODE_USER_DATA_DIR:-$HOME/.vscode-data}"
vscode_extensions_dir="${AI_SANDBOX_VSCODE_EXTENSIONS_DIR:-$HOME/.vscode-extensions}"
vscode_shared_user_dir="${AI_SANDBOX_VSCODE_SHARED_USER_DIR:-$HOME/.vscode-shared-user}"

# Child shells launched via `bash -lc` must see these values.
export vscode_user_data_dir
export vscode_extensions_dir
export vscode_shared_user_dir

mkdir -p \
  "$HOME" \
  "$vscode_user_data_dir" \
  "$vscode_extensions_dir" \
  "$vscode_shared_user_dir" \
  "$vscode_user_data_dir/User" \
  "$XDG_RUNTIME_DIR"

chmod 700 "$XDG_RUNTIME_DIR" || true

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
  local settings="$vscode_user_data_dir/User/settings.json"
  mkdir -p "$(dirname "$settings")"
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

link_shared_vscode_user_files() {
  local user_dir shared_dir
  user_dir="$vscode_user_data_dir/User"
  shared_dir="$vscode_shared_user_dir"

  mkdir -p "$user_dir" "$shared_dir"

  # Share the most user-facing config files between instances so VS Code feels
  # consistent, while keeping Chromium/webview internals isolated.
  for name in settings.json keybindings.json tasks.json locale.json; do
    local target shared_link
    target="$user_dir/$name"
    shared_link="$shared_dir/$name"

    if [[ -f "$target" && ! -e "$shared_link" ]]; then
      mv "$target" "$shared_link"
    fi

    if [[ -e "$target" && ! -L "$target" ]]; then
      rm -rf "$target"
    fi

    ln -sfn "$shared_link" "$target"
  done

  local snippets_target snippets_shared
  snippets_target="$user_dir/snippets"
  snippets_shared="$shared_dir/snippets"
  mkdir -p "$snippets_shared"
  if [[ -e "$snippets_target" && ! -L "$snippets_target" ]]; then
    rm -rf "$snippets_target"
  fi
  ln -sfn "$snippets_shared" "$snippets_target"
}

ensure_ai_shell_prompt_files() {
  mkdir -p "$HOME/.config"

  cat > "$HOME/.config/starship-ai-sandbox.toml" <<'EOF'
format = """
[ AI-SANDBOX ](fg:#0f172a bg:#7dd3fc)[](fg:#7dd3fc bg:#2563eb)$custom.project[](fg:#2563eb bg:#1d4ed8)$directory$git_branch$git_status[](fg:#1d4ed8)
$character"""

add_newline = false

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
vimcmd_symbol = "[❮](bold yellow)"

[custom.project]
command = "printf '%s' \"${AI_SANDBOX_PROJECT_NAME:-workspace}\""
when = "true"
format = "[ $output ]($style)"
style = "fg:#e3e5e5 bg:#2563eb"

[directory]
style = "fg:#e3e5e5 bg:#1d4ed8"
format = "[ $path ]($style)"
truncation_length = 3
truncation_symbol = "…/"
truncate_to_repo = false

[git_branch]
symbol = " "
style = "fg:#fef3c7 bg:#1d4ed8"
format = "[ $symbol$branch ]($style)"

[git_status]
style = "fg:#fef3c7 bg:#1d4ed8"
format = "[$all_status$ahead_behind ]($style)"

[aws]
disabled = true

[gcloud]
disabled = true

[line_break]
disabled = true
EOF

  cat > "$HOME/.ai-sandbox-bashrc" <<'EOF'
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc

# Keep shell startup deterministic by default.
# User bashrc hooks can be re-enabled explicitly when needed.
if [[ "${AI_SANDBOX_SOURCE_USER_BASHRC:-0}" == "1" ]] && [ -f "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi

export HISTFILE="$HOME/.bash_eternal_history"
shopt -s histappend
PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

if command -v starship >/dev/null 2>&1; then
  export STARSHIP_CONFIG="$HOME/.config/starship-ai-sandbox.toml"
  eval "$(starship init bash)"
else
  __ai_sandbox_git_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null | awk '{printf " (%s)", $0}'
  }

  export PS1='\[\033[1;30;106m\] AI-SANDBOX \[\033[0m\] \[\033[1;37;44m\] ${AI_SANDBOX_PROJECT_NAME:-workspace} \[\033[0m\] \w$(__ai_sandbox_git_branch)\n\[\033[1;32m\]\$ \[\033[0m\]'
fi
EOF
}

seed_nix_if_needed
link_shared_vscode_user_files
ensure_default_vscode_settings
ensure_ai_shell_prompt_files

if ! command -v nix >/dev/null 2>&1; then
  echo "nix still not found after seeding. PATH=$PATH" >&2
  exit 1
fi

# Force external URL opens through the host browser via portal.
export BROWSER=/usr/local/bin/ai-sandbox-xdg-open

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

has_usable_dev_shell() {
  [[ -n "$flake_target" ]] || return 1
  nix develop "$flake_target" --command true >/dev/null 2>&1
}

echo "AI_SANDBOX_VSCODE_DIRS: user-data=$vscode_user_data_dir extensions=$vscode_extensions_dir shared-user=$vscode_shared_user_dir"

launch_code_cmd='
  export BROWSER=/usr/local/bin/ai-sandbox-xdg-open
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"

  echo "AI_SANDBOX_READY_VSCODE: launching VS Code for $1"

  code \
    --verbose \
    --user-data-dir "$vscode_user_data_dir" \
    --extensions-dir "$vscode_extensions_dir" \
    "$1"
'

case "$mode" in
  warm)
    if has_usable_dev_shell; then
      if nix develop "$flake_target" --command true; then
        exit 0
      fi
      echo "Flake found at $flake_target but warmup command failed."
      exit 1
    elif [[ -n "$flake_target" ]]; then
      echo "Flake found at $flake_target but no usable devShell; skipping warmup."
      exit 0
    else
      echo "No flake found; nothing to warm."
      exit 0
    fi
    ;;
  shell)
    if has_usable_dev_shell; then
      exec nix develop "$flake_target" --command bash --rcfile "$HOME/.ai-sandbox-bashrc" -i
    elif [[ -n "$flake_target" ]]; then
      echo "Flake found at $flake_target but no usable devShell; starting plain bash."
    fi
    exec bash --rcfile "$HOME/.ai-sandbox-bashrc" -i
    ;;
  start)
    if has_usable_dev_shell; then
      exec nix develop "$flake_target" --command bash -lc "$launch_code_cmd" _ "$workspace"
    elif [[ -n "$flake_target" ]]; then
      echo "Flake found at $flake_target but no usable devShell; launching VS Code without nix develop."
    fi
    exec bash -lc "$launch_code_cmd" _ "$workspace"
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    exit 1
    ;;
esac
