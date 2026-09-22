#!/usr/bin/env bash
set -euo pipefail

commit="${1:?gpt-repo-mcp commit is required}"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Invalid gpt-repo-mcp commit: $commit" >&2
  exit 1
}
install_root="/sandbox-home/.local/share/ai-sandbox/mcp/gpt-repo-mcp"
target="$install_root/$commit"
lock_file="$install_root/install.lock"

mkdir -p "$install_root"
exec 9>"$lock_file"
flock 9

if [[ -f "$target/dist/server.js" && -f "$target/.ai-sandbox-version" ]] &&
  [[ "$(<"$target/.ai-sandbox-version")" == "$commit" ]]; then
  exit 0
fi

temporary="$install_root/.install-$commit-$$"
cleanup() {
  rm -rf -- "$temporary"
}
trap cleanup EXIT
mkdir -p "$temporary"

curl -fL --silent --show-error \
  "https://github.com/CAHN91/gpt-repo-mcp/archive/$commit.tar.gz" |
  tar -xz --strip-components=1 -C "$temporary"

(
  cd "$temporary"
  npm ci --no-audit --no-fund
  npm run build
)
printf '%s\n' "$commit" >"$temporary/.ai-sandbox-version"
rm -rf -- "$target"
mv "$temporary" "$target"
trap - EXIT
