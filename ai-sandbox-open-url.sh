#!/usr/bin/env bash
set -euo pipefail

url="${1:-}"
if [[ -z "$url" ]]; then
  echo "Missing URL" >&2
  exit 1
fi

if code --help 2>&1 | grep -q -- '--open-url'; then
  exec code --open-url "$url"
fi

echo "VS Code CLI on this build does not advertise --open-url; URL callback could not be forwarded cleanly." >&2
exit 1