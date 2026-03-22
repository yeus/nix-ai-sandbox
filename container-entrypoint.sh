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
auto_nix_repair="${AI_SANDBOX_AUTO_NIX_REPAIR:-1}"

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

if [[ -n "${AI_SANDBOX_SHELL_STARTED_FILE:-}" ]]; then
  : > "$AI_SANDBOX_SHELL_STARTED_FILE"
  unset AI_SANDBOX_SHELL_STARTED_FILE
fi

export HISTFILE="$HOME/.bash_eternal_history"
shopt -s histappend
export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# Reset prompt-related state inherited from nix develop or shell hooks so
# starship can initialize bash cleanly.
unset STARSHIP_PROMPT_COMMAND STARSHIP_START_TIME STARSHIP_SHELL STARSHIP_SESSION_KEY
unset BLE_ATTACHED BLE_VERSION BLE_PIPESTATUS
unset bash_preexec_imported __bp_imported
unset preexec_functions precmd_functions
unset PS0
trap - DEBUG 2>/dev/null || true

PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

if command -v starship >/dev/null 2>&1; then
  export STARSHIP_CONFIG="$HOME/.config/starship-ai-sandbox.toml"
  export STARSHIP_SHELL="bash"

  __ai_sandbox_starship_precmd() {
    local last_status=$?
    local -a pipe_status
    local job_count=0
    local job

    pipe_status=("${PIPESTATUS[@]}")
    jobs &>/dev/null
    for job in $(jobs -p); do
      [[ -n "$job" ]] && ((job_count++))
    done

    PS1="$(starship prompt \
      --terminal-width="${COLUMNS:-80}" \
      --status="${last_status}" \
      --pipestatus="${pipe_status[*]}" \
      --jobs="${job_count}" \
      --shlvl="${SHLVL:-1}")"
  }

  PS2="$(starship prompt --continuation)"
  PROMPT_COMMAND="history -a; __ai_sandbox_starship_precmd"
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

flake_target=""
if [[ "$mode" == "start" || "$mode" == "shell" || "$mode" == "warm" ]]; then
  flake_target="$(resolve_flake_target)"
  cd "$workspace"
fi

print_nix_store_recovery_hint() {
  cat >&2 <<'EOF'
Hint: this usually means the shared ai-sandbox /nix cache is corrupted.
You can recover by resetting only the Nix storage cache and keeping VS Code home/settings:
  1) stop running ai-sandbox containers
  2) remove ~/.cache/ai-sandbox/nix
  3) start ai-sandbox again (it will repopulate /nix)
If you prefer a full reset (including sandbox home), run:
  ai-sandbox reset-storage
EOF
}

auto_repair_attempted=0
last_nix_develop_missing_default_devshell=0
last_nix_develop_store_corruption=0

looks_like_nix_store_corruption() {
  local log_file="$1"
  grep -Eiq \
    '(/nix/store/.*: No such file or directory|path .*/nix/store/.* (is missing|is corrupt)|cannot build .*/nix/store/.*\.drv)' \
    "$log_file"
}

run_nix_develop_with_auto_repair() {
  local log_file status
  log_file="$(mktemp)"
  last_nix_develop_missing_default_devshell=0
  last_nix_develop_store_corruption=0

  if nix develop "$flake_target" --command "$@" > >(tee "$log_file") 2>&1; then
    rm -f "$log_file"
    return 0
  else
    status=$?
  fi

  if grep -Fq "does not provide attribute 'devShells." "$log_file"; then
    last_nix_develop_missing_default_devshell=1
    rm -f "$log_file"
    return "$status"
  fi

  if [[ "$auto_nix_repair" == "1" ]] \
    && [[ "$auto_repair_attempted" -eq 0 ]] \
    && looks_like_nix_store_corruption "$log_file"; then
    last_nix_develop_store_corruption=1
    auto_repair_attempted=1
    echo "AI_SANDBOX: detected likely /nix store corruption; running automatic repair and retrying..." >&2
    if nix-store --verify --check-contents --repair; then
      echo "AI_SANDBOX: repair finished; retrying nix develop..." >&2
      if nix develop "$flake_target" --command "$@" > >(tee "$log_file") 2>&1; then
        rm -f "$log_file"
        return 0
      else
        status=$?
      fi
    fi
    echo "AI_SANDBOX: automatic nix-store repair failed." >&2
  fi

  rm -f "$log_file"
  return "$status"
}

echo "AI_SANDBOX_VSCODE_DIRS: user-data=$vscode_user_data_dir extensions=$vscode_extensions_dir shared-user=$vscode_shared_user_dir"

launch_code_cmd='
  export BROWSER=/usr/local/bin/ai-sandbox-xdg-open
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"

  echo "AI_SANDBOX_READY_VSCODE: launching VS Code for $1"
  echo "AI_SANDBOX_HINT: VS Code inherits the environment from nix develop when a flake devShell is available."
  echo "AI_SANDBOX_HINT: Repo-local tools still need project bootstrap inside the sandbox (for example: yarn install, pnpm install, npm install, or your project init command)."
  echo "AI_SANDBOX_HINT: If Codex or the integrated terminal cannot find tools like vue-tsc, first run the project install/bootstrap step inside this sandboxed workspace."

  code \
    --verbose \
    --user-data-dir "$vscode_user_data_dir" \
    --extensions-dir "$vscode_extensions_dir" \
    "$1"
'

case "$mode" in
  repair)
    echo "AI_SANDBOX: repairing shared /nix store cache..."
    nix-store --verify --check-contents --repair
    echo "AI_SANDBOX: nix-store repair completed."
    exit 0
    ;;
  warm)
    if [[ -n "$flake_target" ]]; then
      if run_nix_develop_with_auto_repair true; then
        exit 0
      fi
      if [[ "$last_nix_develop_missing_default_devshell" == "1" ]]; then
        echo "AI_SANDBOX: no default dev shell exported by $flake_target; skipping nix warmup."
        echo "Hint: pass --flake to a different flake, or add devShells.x86_64-linux.default if you want nix develop here."
      else
        echo "Flake found at $flake_target but no usable devShell; skipping warmup."
      fi
      if [[ "$last_nix_develop_store_corruption" == "1" ]]; then
        print_nix_store_recovery_hint
      fi
      exit 0
    else
      echo "AI_SANDBOX: no flake detected for $workspace; skipping nix warmup."
      exit 0
    fi
    ;;
  shell)
    if [[ -n "$flake_target" ]]; then
      echo "AI_SANDBOX: preparing flake dev shell at $flake_target..."
      shell_started_file="$(mktemp)"
      rm -f "$shell_started_file"
      echo "AI_SANDBOX: entering interactive shell..."
      if AI_SANDBOX_SHELL_STARTED_FILE="$shell_started_file" \
        run_nix_develop_with_auto_repair /bin/bash --noprofile --rcfile "$HOME/.ai-sandbox-bashrc" -i; then
        rm -f "$shell_started_file"
        exit 0
      else
        shell_status=$?
      fi
      if [[ -e "$shell_started_file" ]]; then
        rm -f "$shell_started_file"
        exit "$shell_status"
      fi
      rm -f "$shell_started_file"
      if [[ "$last_nix_develop_missing_default_devshell" == "1" ]]; then
        echo "AI_SANDBOX: no default dev shell exported by $flake_target; starting plain bash."
        echo "Hint: pass --flake to a different flake, or add devShells.x86_64-linux.default if you want nix develop here."
      else
        echo "AI_SANDBOX: interactive nix develop shell failed to launch."
        echo "Flake found at $flake_target but nix develop failed; starting plain bash."
      fi
      if [[ "$last_nix_develop_store_corruption" == "1" ]]; then
        print_nix_store_recovery_hint
      fi
    fi
    exec /bin/bash --noprofile --rcfile "$HOME/.ai-sandbox-bashrc" -i
    ;;
  start)
    if [[ -n "$flake_target" ]]; then
      if run_nix_develop_with_auto_repair /bin/bash -lc "$launch_code_cmd" _ "$workspace"; then
        exit 0
      fi
      if [[ "$last_nix_develop_missing_default_devshell" == "1" ]]; then
        echo "AI_SANDBOX: no default dev shell exported by $flake_target; launching VS Code without nix develop."
        echo "Hint: pass --flake to a different flake, or add devShells.x86_64-linux.default if you want nix develop on startup."
      else
        echo "Flake found at $flake_target but no usable devShell; launching VS Code without nix develop."
      fi
      if [[ "$last_nix_develop_store_corruption" == "1" ]]; then
        print_nix_store_recovery_hint
      fi
    fi
    exec /bin/bash -lc "$launch_code_cmd" _ "$workspace"
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    exit 1
    ;;
esac
