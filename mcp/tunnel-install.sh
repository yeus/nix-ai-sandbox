#!/usr/bin/env bash
set -euo pipefail

version="${1:?tunnel-client version is required}"
[[ "$version" == v0.0.14 ]] || {
  echo "Unsupported tunnel-client version: $version" >&2
  exit 1
}

case "$(uname -m)" in
  x86_64)
    platform=linux-amd64
    checksum=15bd17e805cad39d412199115bb9e10a978dd35258a114cdf25dd2ae6681c7d3
    ;;
  aarch64|arm64)
    platform=linux-arm64
    checksum=2de3fb879a18edb847e0313592c912f1983685488290a7fdba7ac403e6a4fb0a
    ;;
  *)
    echo "Unsupported tunnel-client architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

install_root=/sandbox-home/.local/share/ai-sandbox/mcp/tunnel-client
target="$install_root/$version-$platform"
archive_name="tunnel-client-$version-$platform.zip"
lock_file="$install_root/install.lock"

mkdir -p "$install_root"
exec 9>"$lock_file"
flock 9

if [[ -x "$target/tunnel-client" && -f "$target/.ai-sandbox-version" ]] &&
  [[ "$(<"$target/.ai-sandbox-version")" == "$version-$platform" ]]; then
  exit 0
fi

temporary="$install_root/.install-$version-$platform-$$"
archive="$temporary/$archive_name"
cleanup() {
  rm -rf -- "$temporary"
}
trap cleanup EXIT
mkdir -p "$temporary"
curl -fL --silent --show-error \
  "https://github.com/openai/tunnel-client/releases/download/$version/$archive_name" \
  -o "$archive"
printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c -
unzip -q "$archive" -d "$temporary/unpacked"
printf '%s\n' "$version-$platform" \
  >"$temporary/unpacked/.ai-sandbox-version"
chmod 0755 \
  "$temporary/unpacked/tunnel-client" \
  "$temporary/unpacked/cloudflared"
rm -rf -- "$target"
mv "$temporary/unpacked" "$target"
trap - EXIT
cleanup
