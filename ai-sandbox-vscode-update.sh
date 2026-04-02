#!/usr/bin/env bash
set -euo pipefail

mode="${1:---if-missing}"

install_root="${HOME}/.local/opt/vscode"
current_dir="${install_root}/current"
bin_dir="${install_root}/bin"
code_bin="${bin_dir}/code"
download_url="${AI_SANDBOX_VSCODE_DOWNLOAD_URL:-https://update.code.visualstudio.com/latest/linux-x64/stable}"

case "$mode" in
  --if-missing)
    if [[ -x "$code_bin" ]]; then
      exit 0
    fi
    ;;
  --force)
    ;;
  *)
    echo "Usage: ai-sandbox-vscode-update.sh [--if-missing|--force]" >&2
    exit 2
    ;;
esac

tmp_dir="$(mktemp -d)"
archive_path="${tmp_dir}/vscode.tar.gz"
trap 'rm -rf "$tmp_dir"' EXIT

echo "AI_SANDBOX: installing user-space VS Code at ${install_root} ..."
curl -fsSL "$download_url" -o "$archive_path"
tar -xzf "$archive_path" -C "$tmp_dir"

src_dir="${tmp_dir}/VSCode-linux-x64"
if [[ ! -d "$src_dir" ]]; then
  echo "AI_SANDBOX: failed to unpack VS Code archive." >&2
  exit 1
fi

mkdir -p "$install_root"
rm -rf "$current_dir"
mv "$src_dir" "$current_dir"
mkdir -p "$bin_dir"
ln -sfn "${current_dir}/bin/code" "$code_bin"

echo "AI_SANDBOX: VS Code installed/updated in ${current_dir}"
