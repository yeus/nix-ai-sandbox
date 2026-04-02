#!/usr/bin/env bash
set -euo pipefail

url="${1:-}"
if [[ -z "$url" ]]; then
  echo "Missing URL" >&2
  exit 1
fi

# Decode percent-encoded strings without requiring python/perl.
urldecode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

# Some auth flows may bounce through vscode.dev/redirect and carry the final
# callback in a URL-encoded query param.
if [[ "$url" == "https://vscode.dev/redirect"* || "$url" == "https://insiders.vscode.dev/redirect"* ]]; then
  query="${url#*\?}"
  state=""
  callback=""
  IFS='&' read -r -a parts <<< "$query"
  for part in "${parts[@]}"; do
    key="${part%%=*}"
    val="${part#*=}"
    if [[ "$key" == "state" ]]; then
      state="$val"
    fi
    if [[ "$key" == "url" ]]; then
      callback="$val"
    fi
  done

  candidate="${callback:-$state}"
  if [[ -n "$candidate" ]]; then
    decoded="$candidate"
    for _ in 1 2 3; do
      decoded="$(urldecode "$decoded")"
      if [[ "$decoded" == vscode://* || "$decoded" == vscode-insiders://* ]]; then
        url="$decoded"
        break
      fi
    done
  fi
fi

if [[ -x /usr/local/bin/ai-sandbox-default-install ]]; then
  /usr/local/bin/ai-sandbox-default-install --only vscode
fi

exec code \
  --user-data-dir "${AI_SANDBOX_VSCODE_USER_DATA_DIR:-$HOME/.vscode-data}" \
  --extensions-dir "${AI_SANDBOX_VSCODE_EXTENSIONS_DIR:-$HOME/.vscode-extensions}" \
  --open-url "$url"
