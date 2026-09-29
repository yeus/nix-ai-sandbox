#!/usr/bin/env bash
set -euo pipefail

version="${1:?cloudflared version is required}"
[[ "$version" == 2026.9.3 ]] || {
  echo "Unsupported cloudflared version: $version" >&2
  exit 1
}

case "$(uname -m)" in
  x86_64)
    asset=cloudflared-linux-amd64
    checksum=77e26d8d900e0b8469f416239d14b5f296525fdf79fee6f511ef55609e3fbac2
    ;;
  aarch64|arm64)
    asset=cloudflared-linux-arm64
    checksum=aaeb2d7d0da3614634c7e03ab13487a1522c2e79165ed2929cfe23d5e95b326d
    ;;
  *)
    echo "Unsupported cloudflared architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

install_root=/sandbox-home/.local/share/ai-sandbox/mcp/cloudflared
target="$install_root/$version"
binary="$target/cloudflared"
lock_file="$install_root/install.lock"
mkdir -p "$install_root"
exec 9>"$lock_file"
flock 9
[[ -x "$binary" ]] && exit 0

temporary="$install_root/.install-$version-$$"
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary"
download="$temporary/cloudflared"
curl -fL --silent --show-error \
  "https://github.com/cloudflare/cloudflared/releases/download/$version/$asset" \
  -o "$download"
printf '%s  %s\n' "$checksum" "$download" | sha256sum -c -
chmod 0755 "$download"
mkdir -p "$target"
mv "$download" "$binary"
trap - EXIT
rm -rf -- "$temporary"
