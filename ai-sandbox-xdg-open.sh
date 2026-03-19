#!/usr/bin/env bash
set -euo pipefail

url="${1:-}"
if [[ -z "$url" ]]; then
  echo "Missing URL for xdg-open wrapper" >&2
  exit 1
fi

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  echo "DBUS_SESSION_BUS_ADDRESS is not set; cannot reach host portal." >&2
  exit 1
fi

# Prefer desktop portal to open in the host browser.
# Parent window is empty string because we are in a containerized X11 app.
exec gdbus call \
  --session \
  --dest org.freedesktop.portal.Desktop \
  --object-path /org/freedesktop/portal/desktop \
  --method org.freedesktop.portal.OpenURI.OpenURI \
  "" \
  "$url" \
  "{}"