#!/usr/bin/env bash
set -euo pipefail

force=0
only="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      force=1
      shift
      ;;
    --only)
      shift
      [[ $# -gt 0 ]] || { echo "--only requires all|codex|vscode" >&2; exit 2; }
      only="$1"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: ai-sandbox-default-install [--force] [--only all|codex|vscode]" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$HOME/.local/bin" "$HOME/.local/opt" "$HOME/.npm-global/bin"
export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-$HOME/.npm-global}"
export PATH="$HOME/.local/bin:$NPM_CONFIG_PREFIX/bin:$HOME/.local/opt/vscode/bin:$PATH"

install_codex() {
  if [[ "$force" -eq 0 ]] && command -v codex >/dev/null 2>&1; then
    echo "AI_SANDBOX: Codex already present in user space; skipping."
    return
  fi
  echo "AI_SANDBOX: installing Codex in user space..."
  npm install -g @openai/codex@latest
  echo "AI_SANDBOX: Codex installation complete."
}

install_vscode() {
  echo "AI_SANDBOX: ensuring user-space VS Code is available..."
  if [[ "$force" -eq 1 ]]; then
    /usr/local/bin/ai-sandbox-vscode-update --force
    echo "AI_SANDBOX: VS Code forced update complete."
    return
  fi
  /usr/local/bin/ai-sandbox-vscode-update --if-missing
  echo "AI_SANDBOX: VS Code check/install complete."
}

case "$only" in
  all)
    install_codex
    install_vscode
    ;;
  codex)
    install_codex
    ;;
  vscode)
    install_vscode
    ;;
  *)
    echo "Invalid --only value: $only (expected all|codex|vscode)" >&2
    exit 2
    ;;
esac
