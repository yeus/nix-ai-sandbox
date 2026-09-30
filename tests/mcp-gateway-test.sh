#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
gateway_pid=""
upstream_pid_a=""
upstream_pid_b=""
cleanup() {
  [[ -z "$gateway_pid" ]] || kill "$gateway_pid" 2>/dev/null || true
  [[ -z "$upstream_pid_a" ]] || kill "$upstream_pid_a" 2>/dev/null || true
  [[ -z "$upstream_pid_b" ]] || kill "$upstream_pid_b" 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

export HOME_STORAGE="$test_root/home"
export SECRETS_STORAGE="$test_root/secrets"
export STATE_DIR="$test_root/state"
export HOME_STORAGE="$HOME_STORAGE"
export SECRETS_STORAGE="$SECRETS_STORAGE"
export AI_SANDBOX_STATE_DIR="$STATE_DIR"
export AI_SANDBOX_MCP_LIB_DIR="$repo_root/mcp"
mkdir -p "$HOME_STORAGE" "$SECRETS_STORAGE" "$STATE_DIR"

source "$repo_root/mcp/host.sh"
source "$repo_root/mcp/gateway.sh"

gateway_bin="${AI_SANDBOX_MCP_GATEWAY_BIN:-}"
if [[ -z "$gateway_bin" ]]; then
  command -v go >/dev/null 2>&1 ||
    fail "go is required to build the gateway or set AI_SANDBOX_MCP_GATEWAY_BIN"
  (cd "$repo_root/mcp/gateway" && go build -o "$test_root/ai-sandbox-mcp-gateway" .)
  gateway_bin="$test_root/ai-sandbox-mcp-gateway"
fi
export AI_SANDBOX_MCP_GATEWAY_BIN="$gateway_bin"

gateway_root="$SECRETS_STORAGE/mcp/gateway"
registry="$gateway_root/registry.json"
hash_a=aaaa111122223333
hash_b=bbbb111122223333
token_a=bearer-token-aaaaaaaaaaaaaaaaaaaaaaaaaaaa
token_b=bearer-token-bbbbbbbbbbbbbbbbbbbbbbbbbbbb

# --- registry: setup, permissions, persistence ------------------------------

mcp_gateway_setup 3 >/dev/null
[[ -f "$registry" ]] || fail "gateway setup did not write the registry"
[[ "$(stat -c %a "$SECRETS_STORAGE")" == 700 ]] ||
  fail "secrets root permissions are not 0700"
[[ "$(stat -c %a "$gateway_root")" == 700 ]] ||
  fail "gateway state directory permissions are not 0700"
[[ "$(stat -c %a "$registry")" == 600 ]] ||
  fail "registry permissions are not 0600"
[[ "$(stat -c %a "$gateway_root/tokens")" == 700 ]] ||
  fail "token directory permissions are not 0700"
[[ "$(stat -c %a "$gateway_root/tokens/1")" == 600 ]] ||
  fail "slot token permissions are not 0600"
for slot in 1 2 3; do
  rg -qx '[a-f0-9]{64}' "$gateway_root/tokens/$slot" ||
    fail "slot token $slot is not 32 random bytes as hex"
done
jq -e '.version == 1 and .size == 3 and .auth == "capability" and (.slots | length) == 0' \
  "$registry" >/dev/null || fail "unexpected initial registry content"

mcp_gateway_assign "$hash_a" "/projects/a" mcp1 1 0
mcp_gateway_assign "$hash_b" "/projects/b" mcp2 2 0
[[ "$(mcp_gateway_slot_owner 1)" == "$hash_a" ]] || fail "slot 1 owner mismatch"
[[ "$(mcp_gateway_slot_for_hash "$hash_b")" == 2 ]] || fail "workspace b slot mismatch"
[[ "$(jq -r '.slots | length' "$registry")" == 2 ]] || fail "registry did not persist assignments"
[[ "$(stat -c %a "$registry")" == 600 ]] || fail "registry permissions changed after mutation"

# reloading allocation from disk (fresh function call, same registry file)
[[ "$(mcp_gateway_slot_owner 1)" == "$hash_a" ]] || fail "allocation did not survive reload"

if mcp_gateway_assign "$hash_b" "/projects/b" mcp2 1 0 2>"$test_root/dup.err"; then
  fail "assigning an occupied slot to another workspace was accepted"
fi
rg -q 'already assigned' "$test_root/dup.err" ||
  fail "occupied slot rejection did not explain the conflict"

mcp_gateway_unassign "$hash_b" >/dev/null
if mcp_gateway_assign "$hash_a" "/projects/a" mcp1 2 0 2>"$test_root/two.err"; then
  fail "assigning a second slot to one workspace was accepted"
fi
rg -q 'already assigned to slot 1' "$test_root/two.err" ||
  fail "second-slot rejection did not name the existing slot"

# explicit takeover moves the workspace and frees its old slot
mcp_gateway_assign "$hash_a" "/projects/a" mcp1 2 1
[[ "$(mcp_gateway_slot_owner 2)" == "$hash_a" ]] || fail "takeover did not move the workspace"
[[ -z "$(mcp_gateway_slot_owner 1)" ]] || fail "takeover did not release the old slot"

# explicit takeover replaces the occupant of an occupied slot
mcp_gateway_assign "$hash_b" "/projects/b" mcp2 2 1
[[ "$(mcp_gateway_slot_owner 2)" == "$hash_b" ]] || fail "slot takeover was not applied"

# pool shrink refuses to drop an assigned slot
if mcp_gateway_setup 1 >/dev/null 2>"$test_root/shrink.err"; then
  fail "shrinking below an assigned slot was accepted"
fi
rg -q 'below the highest assigned slot' "$test_root/shrink.err" ||
  fail "shrink rejection did not explain the conflict"

# explicit release
mcp_gateway_unassign "$hash_b" >/dev/null
[[ -z "$(mcp_gateway_slot_owner 2)" ]] || fail "explicit release did not free the slot"
mcp_gateway_unassign "$hash_b" >/dev/null || fail "repeat release was not idempotent"

# symlink attack against the registry is refused
mv "$registry" "$registry.real"
ln -s "$registry.real" "$registry"
if mcp_gateway_assign "$hash_a" "/projects/a" mcp1 1 0 2>/dev/null; then
  fail "assigning through a symlinked registry was accepted"
fi
rm -f "$registry"
mv "$registry.real" "$registry"

# symlink attack against a slot token is refused
rm -f "$gateway_root/tokens/2"
ln -s "$gateway_root/tokens/1" "$gateway_root/tokens/2"
if mcp_gateway_ensure_tokens 3 2>/dev/null; then
  fail "symlinked slot token was accepted"
fi
rm -f "$gateway_root/tokens/2"
mcp_gateway_ensure_tokens 3

# concurrent mutations: all distinct slots land, no lost updates
mcp_gateway_setup 24 >/dev/null
assign_pids=()
for slot in $(seq 1 16); do
  (
    hash="$(printf 'c%05d' "$slot")0000"
    mcp_gateway_assign "$hash" "/projects/c$slot" "mcp$slot" "$slot" 0
  ) &
  assign_pids+=("$!")
done
wait "${assign_pids[@]}"
[[ "$(jq -r '.slots | length' "$registry")" == 16 ]] ||
  fail "concurrent assignments lost registry entries"
for slot in $(seq 1 16); do
  jq -e --arg slot "$slot" '.slots[$slot] != null' "$registry" >/dev/null ||
    fail "concurrent assignment for slot $slot is missing"
done
# reset to the routing fixture
for slot in $(seq 1 16); do
  mcp_gateway_unassign "$(printf 'c%05d' "$slot")0000" >/dev/null
done
mcp_gateway_assign "$hash_a" "/projects/a" mcp1 1 0
mcp_gateway_assign "$hash_b" "/projects/b" mcp2 2 0

# --- routing fixtures --------------------------------------------------------

cat >"$test_root/upstream.py" <<'PYEOF'
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

name = sys.argv[1]
port = int(sys.argv[2])
log_path = sys.argv[3]
port_file = sys.argv[4] if len(sys.argv) > 4 else ""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def record(self):
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({
                "method": self.command,
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "session": self.headers.get("Mcp-Session-Id"),
                "last_event": self.headers.get("Last-Event-ID"),
            }) + "\n")

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length).decode("utf-8") if length else ""

    def send_json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_request(self):
        self.record()
        body = self.read_body()
        query = parse_qs(urlparse(self.path).query)
        mode = (query.get("mode") or [""])[0]
        if mode == "stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for index in range(3):
                chunk = ("data: chunk-%d from %s\n\n" % (index, name)).encode("utf-8")
                self.wfile.write(("%x\r\n" % len(chunk)).encode("ascii") + chunk + b"\r\n")
                self.wfile.flush()
                time.sleep(0.05)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        if mode == "fail":
            self.send_json(500, {"server": name, "error": "synthetic"})
            return
        self.send_json(200, {
            "server": name,
            "authorization": self.headers.get("Authorization"),
            "body": body,
            "session": self.headers.get("Mcp-Session-Id"),
            "last_event": self.headers.get("Last-Event-ID"),
        })

    do_GET = handle_request
    do_POST = handle_request
    do_DELETE = handle_request


server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
if port_file:
    with open(port_file, "w", encoding="utf-8") as handle:
        handle.write("%d\n" % server.server_address[1])
server.serve_forever()
PYEOF

pick_port() {
  python3 - <<'PYEOF'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PYEOF
}

log_a="$test_root/upstream-a.jsonl"
log_b="$test_root/upstream-b.jsonl"
: >"$log_a"
: >"$log_b"

start_upstream() {
  local name="$1" log="$2" port_file="$test_root/$1.port"
  rm -f "$port_file"
  python3 "$test_root/upstream.py" "$name" 0 "$log" "$port_file" &
  upstream_reported_pid=$!
  for _ in {1..80}; do
    [[ -s "$port_file" ]] && break
    sleep 0.05
  done
  [[ -s "$port_file" ]] || fail "upstream $name did not report a port"
  upstream_reported_port="$(<"$port_file")"
}

start_upstream upstream-a "$log_a"
upstream_pid_a="$upstream_reported_pid"
port_a="$upstream_reported_port"
start_upstream upstream-b "$log_b"
upstream_pid_b="$upstream_reported_pid"
port_b="$upstream_reported_port"

setup_workspace() {
  local hash="$1" port="$2" token="$3" style="${4:-writer}"
  local runtime="$HOME_STORAGE/.ai-sandbox/mcp-winx/$hash"
  local secret_dir="$SECRETS_STORAGE/mcp/$hash"
  mkdir -p "$runtime/runtime" "$secret_dir"
  if [[ "$style" == legacy ]]; then
    jq -n --arg port "$port" \
      '{transport: "streamable-http", host_port: $port}' \
      >"$runtime/runtime/metadata.json"
  else
    mcp_write_metadata \
      "$runtime/runtime/metadata.json" \
      synthetic write synthetic-mcp 0 default streamable-http \
      "" "$port" "" 0
  fi
  printf '%s\n' "$token" >"$secret_dir/bearer-token"
  chmod 0600 "$secret_dir/bearer-token"
}

# Slot 1 uses the real metadata writer (numeric host_port); slot 2 simulates a
# pre-existing string-typed metadata file that must keep routing.
setup_workspace "$hash_a" "$port_a" "$token_a" writer
setup_workspace "$hash_b" "$port_b" "$token_b" legacy

gw_port="$(pick_port)"
mcp_gateway_mutate --argjson port "$gw_port" '.port = $port'

start_gateway() {
  mcp_gateway_start >/dev/null
  gateway_pid="$(<"$(mcp_gateway_pid_file)")"
  for _ in {1..60}; do
    curl -fsS "http://127.0.0.1:$gw_port/healthz" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  tail -40 "$(mcp_gateway_state_dir)/gateway.log" >&2 || true
  fail "gateway did not become ready"
}

stop_gateway() {
  mcp_gateway_stop >/dev/null
  gateway_pid=""
}

start_gateway
mcp_gateway_running || fail "gateway pid tracking is not running"
stop_gateway
mcp_gateway_running && fail "gateway stop left a running process"
start_gateway
token_cap_a="$(mcp_gateway_slot_token 1)"
token_cap_b="$(mcp_gateway_slot_token 2)"
capability_a="$(<"$gateway_root/tokens/1")"
capability_b="$(<"$gateway_root/tokens/2")"

slot_request() {
  local method="$1" slot="$2" token="$3" suffix="${4:-}" data="${5:-}"
  local args=(-sS -o "$test_root/body" -w '%{http_code}' -X "$method")
  [[ -z "$data" ]] || args+=(--data "$data")
  curl "${args[@]}" \
    "http://127.0.0.1:$gw_port/slot/$slot/$token/mcp$suffix"
}

# --- routing and isolation ---------------------------------------------------

code="$(slot_request POST 1 "$capability_a" '' '{"initialize":true}')"
[[ "$code" == 200 ]] || fail "slot 1 request returned $code"
jq -e '.server == "upstream-a"' "$test_root/body" >/dev/null ||
  fail "slot 1 did not reach upstream A"
jq -e --arg token "Bearer $token_a" '.authorization == $token' "$test_root/body" >/dev/null ||
  fail "gateway did not inject the workspace bearer token"

code="$(slot_request POST 2 "$capability_b" '' '{"initialize":true}')"
[[ "$code" == 200 ]] || fail "slot 2 request returned $code"
jq -e '.server == "upstream-b"' "$test_root/body" >/dev/null ||
  fail "slot 2 did not reach upstream B"

code="$(slot_request POST 1 "$capability_b" '' '{}')"
[[ "$code" == 404 ]] || fail "slot 1 accepted another slot's capability token ($code)"
code="$(slot_request POST 1 "$(printf 'f%.0s' {1..64})" '' '{}')"
[[ "$code" == 404 ]] || fail "slot 1 accepted a fabricated capability token ($code)"
code="$(slot_request POST 9 "$capability_a" '' '{}')"
[[ "$code" == 404 ]] || fail "unconfigured slot was not 404 ($code)"

code="$(slot_request POST 3 "$(mcp_gateway_slot_token 3)" '' '{}')"
[[ "$code" == 503 ]] || fail "free slot did not return 503 ($code)"
jq -e '.error == "slot_free"' "$test_root/body" >/dev/null ||
  fail "free slot did not report slot_free"

# header-form capability token for local tooling
code="$(curl -sS -o "$test_root/body" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $capability_a" --data '{}' \
  "http://127.0.0.1:$gw_port/slot/1/mcp")"
[[ "$code" == 200 ]] || fail "header capability token was rejected ($code)"
jq -e --arg token "Bearer $token_a" '.authorization == $token' "$test_root/body" >/dev/null ||
  fail "header-form request did not inject the workspace token"

# a client-supplied Authorization header never overrides the injected token
code="$(curl -sS -o "$test_root/body" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer attacker-supplied" --data '{}' \
  "http://127.0.0.1:$gw_port/slot/1/$capability_a/mcp")"
[[ "$code" == 200 ]] || fail "request with client Authorization failed ($code)"
jq -e --arg token "Bearer $token_a" '.authorization == $token' "$test_root/body" >/dev/null ||
  fail "client Authorization header reached the upstream"

# path traversal cannot select another slot
code="$(curl -sS -o "$test_root/body" -w '%{http_code}' --path-as-is -X POST \
  "http://127.0.0.1:$gw_port/slot/1/$capability_a/../2/$capability_b/mcp")"
[[ "$code" == 404 ]] || fail "path traversal reached slot $code"

# session headers, query strings, and methods pass through
code="$(slot_request POST 1 "$capability_a" '?mode=normal' '{"session":true}')"
[[ "$code" == 200 ]] || fail "session request failed ($code)"

code="$(curl -sS -o "$test_root/body" -w '%{http_code}' -X POST \
  -H "Mcp-Session-Id: synthetic-session" \
  -H "Last-Event-ID: 41" \
  --data '{}' \
  "http://127.0.0.1:$gw_port/slot/1/$capability_a/mcp?trace=1")"
[[ "$code" == 200 ]] || fail "query/session request failed ($code)"
rg -q '"path": "/mcp\?trace=1"' "$log_a" ||
  fail "query string was not forwarded to the upstream"

code="$(slot_request DELETE 1 "$capability_a" '' '{}')"
[[ "$code" == 200 ]] || fail "DELETE did not pass through ($code)"

# upstream HTTP errors pass through unchanged
code="$(slot_request POST 1 "$capability_a" '?mode=fail' '{}')"
[[ "$code" == 500 ]] || fail "upstream 500 was rewritten to $code"

# streaming (SSE) responses pass through chunk by chunk
code="$(slot_request POST 1 "$capability_a" '?mode=stream' '{}')"
[[ "$code" == 200 ]] || fail "stream request failed ($code)"
body="$(<"$test_root/body")"
for index in 0 1 2; do
  [[ "$body" == *"chunk-$index from upstream-a"* ]] ||
    fail "stream chunk $index is missing"
done

# --- parallel traffic --------------------------------------------------------

: >"$log_a"
: >"$log_b"
parallel_pids=()
for _ in $(seq 1 20); do
  slot_request POST 1 "$capability_a" '' '{"parallel":1}' >/dev/null &
  parallel_pids+=("$!")
  slot_request POST 2 "$capability_b" '' '{"parallel":1}' >/dev/null &
  parallel_pids+=("$!")
done
wait "${parallel_pids[@]}"
count_a="$(wc -l <"$log_a")"
count_b="$(wc -l <"$log_b")"
[[ "$count_a" -ge 20 ]] || fail "upstream A saw only $count_a parallel requests"
[[ "$count_b" -ge 20 ]] || fail "upstream B saw only $count_b parallel requests"

# --- lifecycles --------------------------------------------------------------

# stopped workspace: controlled 503 while the gateway keeps serving slot 2
kill "$upstream_pid_a"
wait "$upstream_pid_a" 2>/dev/null || true
curl -fsS "http://127.0.0.1:$gw_port/healthz" >/dev/null ||
  fail "gateway died with the workspace"
code="$(slot_request POST 1 "$capability_a" '' '{}')"
[[ "$code" == 503 ]] || fail "stopped workspace did not return 503 ($code)"
jq -e '.error == "slot_unavailable"' "$test_root/body" >/dev/null ||
  fail "stopped workspace did not report slot_unavailable"
code="$(slot_request POST 2 "$capability_b" '' '{}')"
[[ "$code" == 200 ]] || fail "slot 2 broke while slot 1 was down ($code)"

# restarting the workspace restores service
python3 "$test_root/upstream.py" upstream-a "$port_a" "$log_a" "" &
upstream_pid_a=$!
for _ in {1..40}; do
  code="$(slot_request POST 1 "$capability_a" '' '{}')"
  [[ "$code" == 200 ]] && break
  sleep 0.1
done
[[ "$code" == 200 ]] || fail "restarted workspace did not recover"

# gateway restart keeps memberships and capability tokens
stop_gateway
start_gateway
[[ "$(mcp_gateway_slot_owner 1)" == "$hash_a" ]] || fail "slot 1 mapping lost on gateway restart"
[[ "$(mcp_gateway_slot_owner 2)" == "$hash_b" ]] || fail "slot 2 mapping lost on gateway restart"
[[ "$(mcp_gateway_slot_token 1)" == "$token_cap_a" ]] || fail "slot 1 capability token changed"
code="$(slot_request POST 1 "$capability_a" '' '{}')"
[[ "$code" == 200 ]] || fail "slot 1 failed after gateway restart ($code)"
code="$(slot_request POST 2 "$capability_b" '' '{}')"
[[ "$code" == 200 ]] || fail "slot 2 failed after gateway restart ($code)"

# --- secrets -----------------------------------------------------------------

jq -e '.server != null' "$test_root/body" >/dev/null
if rg -q -F "$token_a" "$test_root/body"; then
  fail "internal bearer token leaked to the external client"
fi
if rg -q -F "$token_a" <(mcp_gateway_print_status 0); then
  fail "status output leaked the internal bearer token"
fi
if rg -q -F "$capability_a" <(mcp_gateway_print_status 0); then
  fail "status output leaked a capability token"
fi
if rg -q -F "$token_a" "$registry"; then
  fail "registry contains the internal bearer token"
fi
if rg -q -F "$capability_a" "$registry"; then
  fail "registry contains a capability token"
fi
ps -o args= -p "$gateway_pid" >"$test_root/gateway-args"
if rg -q -F "$token_a" "$test_root/gateway-args" ||
  rg -q -F "$capability_a" "$test_root/gateway-args"; then
  fail "gateway process arguments contain secrets"
fi
if rg -q -F "$token_a" "$(mcp_gateway_state_dir)/gateway.log"; then
  fail "gateway log contains the internal bearer token"
fi

echo "MCP gateway tests passed"
