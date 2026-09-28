#!/usr/bin/env bash
set -euo pipefail

version="${1:?Winx version is required}"
[[ "$version" == v0.2.351 ]] || {
  echo "Unsupported Winx version: $version" >&2
  exit 1
}
[[ "$(uname -m)" == x86_64 ]] || {
  echo "Winx $version has no verified Linux binary for $(uname -m)." >&2
  exit 1
}

checksum=755fd84fb8c57c398c49715c2129c994b06bdd7c2c70e0b8f37772b6bd330a35
install_root=/sandbox-home/.local/share/ai-sandbox/mcp/winx
target="$install_root/$version"
lock_file="$install_root/install.lock"
mkdir -p "$install_root"
exec 9>"$lock_file"
flock 9
[[ -x "$target/winx-code-agent" ]] && exit 0

temporary="$install_root/.install-$version-$$"
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary"
archive="$temporary/winx-linux-amd64.tar.gz"
curl -fL --silent --show-error \
  "https://github.com/gabrielmaialva33/winx-code-agent/releases/download/$version/winx-linux-amd64.tar.gz" \
  -o "$archive"
printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c -
tar -xzf "$archive" -C "$temporary"
for binary in winx-code-agent winxd winx-guardian; do
  [[ -x "$temporary/$binary" ]] || {
    echo "Winx release is missing $binary." >&2
    exit 1
  }
done
rm -f "$archive"
rm -rf -- "$target"
mv "$temporary" "$target"
trap - EXIT
