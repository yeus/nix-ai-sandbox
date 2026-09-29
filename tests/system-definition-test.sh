#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
definition="$repo_root/SYSTEM_DEFINITION.csv"
expected_header='id,category,feature,description,status,surface,security_boundary,implementation,verification,milestone,source,notes'

[[ -f "$definition" ]] || { echo "Missing SYSTEM_DEFINITION.csv" >&2; exit 1; }
[[ "$(head -n1 "$definition")" == "$expected_header" ]] || {
  echo "Unexpected SYSTEM_DEFINITION.csv header" >&2
  exit 1
}

duplicates="$(tail -n +2 "$definition" | cut -d, -f1 | sort | uniq -d)"
[[ -z "$duplicates" ]] || {
  echo "Duplicate system definition IDs:" >&2
  printf '%s\n' "$duplicates" >&2
  exit 1
}

required_ids=(
  mcp-openai-secure-tunnel
  mcp-streamable-http-local
  mcp-persistent-api-key
  mcp-api-key-isolation
  mcp-cloudflare-named
  mcp-cloudflare-quick
  mcp-nat-publishing
  mcp-multiple-workspaces
  mcp-persistent-identity
)
for id in "${required_ids[@]}"; do
  rg -q "^${id}," "$definition" || {
    echo "Missing required system definition: $id" >&2
    exit 1
  }
done

while IFS=, read -r id category feature description status surface boundary implementation verification milestone source notes; do
  [[ -n "$id" && -n "$category" && -n "$feature" && -n "$description" ]] || {
    echo "Incomplete system definition row: $id" >&2
    exit 1
  }
  case "$status" in
    planned|implemented|tracked) ;;
    *) echo "Invalid status for $id: $status" >&2; exit 1 ;;
  esac
  IFS=';' read -ra implementation_paths <<<"$implementation"
  for path in "${implementation_paths[@]}"; do
    [[ -z "$path" || -e "$repo_root/$path" ]] || {
      echo "Missing implementation path for $id: $path" >&2
      exit 1
    }
  done
  IFS=';' read -ra verification_paths <<<"$verification"
  for path in "${verification_paths[@]}"; do
    [[ -z "$path" || -e "$repo_root/$path" ]] || {
      echo "Missing verification path for $id: $path" >&2
      exit 1
    }
  done
done < <(tail -n +2 "$definition")

echo "AI Sandbox system definition checks passed"
