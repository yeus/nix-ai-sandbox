#!/usr/bin/env bash
set -euo pipefail

mode="${1:---if-missing}"
install_root="${HOME}/.local/opt/code-server"
current_dir="${install_root}/current"
bin_dir="${install_root}/bin"
code_server_bin="${bin_dir}/code-server"

case "$mode" in
  --if-missing)
    if [[ -x "$code_server_bin" ]]; then
      exit 0
    fi
    ;;
  --force)
    ;;
  *)
    echo "Usage: ai-sandbox-code-server-update.sh [--if-missing|--force]" >&2
    exit 2
    ;;
esac

mkdir -p "$install_root"
exec 9>"$install_root/.update.lock"
flock 9

if [[ "$mode" == "--if-missing" && -x "$code_server_bin" ]]; then
  exit 0
fi

case "$(uname -m)" in
  x86_64) archive_arch="amd64" ;;
  aarch64|arm64) archive_arch="arm64" ;;
  *)
    echo "AI_SANDBOX: unsupported code-server architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

version="${AI_SANDBOX_CODE_SERVER_VERSION:-}"
if [[ -z "$version" ]]; then
  version="$(
    curl -fsSL https://api.github.com/repos/coder/code-server/releases/latest |
      jq -er '.tag_name | ltrimstr("v")'
  )"
fi

download_url="${AI_SANDBOX_CODE_SERVER_DOWNLOAD_URL:-https://github.com/coder/code-server/releases/download/v${version}/code-server-${version}-linux-${archive_arch}.tar.gz}"
release_dir="${install_root}/releases/${version}-${archive_arch}"
if [[ "$mode" == "--force" ]]; then
  release_dir="${release_dir}-$(date -u +%Y%m%d%H%M%S)-$$"
fi
tmp_dir="$(mktemp -d)"
archive_path="${tmp_dir}/code-server.tar.gz"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ ! -x "$release_dir/bin/code-server" ]]; then
  echo "AI_SANDBOX: installing code-server ${version} at ${install_root} ..."
  curl -fsSL "$download_url" -o "$archive_path"
  tar -xzf "$archive_path" -C "$tmp_dir"

  src_dir="${tmp_dir}/code-server-${version}-linux-${archive_arch}"
  if [[ ! -d "$src_dir" ]]; then
    echo "AI_SANDBOX: failed to unpack code-server archive." >&2
    exit 1
  fi

  mkdir -p "${install_root}/releases"
  mv "$src_dir" "$release_dir"
fi

mkdir -p "$bin_dir"
next_link="${install_root}/.current.$$"
ln -s "$release_dir" "$next_link"
mv -Tf "$next_link" "$current_dir"
ln -sfn "${current_dir}/bin/code-server" "$code_server_bin"

echo "AI_SANDBOX: code-server installed/updated in ${current_dir}"
