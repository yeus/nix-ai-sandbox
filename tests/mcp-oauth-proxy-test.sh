#!/usr/bin/env bash
#
# One-workspace proof for a prebuilt MCP OAuth proxy (sigbit/mcp-auth-proxy)
# in front of a Winx-style Streamable HTTP MCP upstream.
#
# Verifies the properties required by docs/agent_handoff.md:
#   - ChatGPT-compatible OAuth 2.1 discovery (PRM + AS metadata + DCR)
#   - authorization-code + PKCE flow with a single owner password
#   - resource parameter echoed on both authorization and token requests
#   - JWT audience enforcement independently of signature trust (shared key)
#   - a token for one endpoint is rejected by another endpoint
#   - the internal upstream bearer is injected and never exposed to the client
#   - /mcp path mapping, session headers, and SSE passthrough
#   - refresh tokens and registrations survive a proxy restart
#   - proxy secrets arrive through the environment, not process arguments
#
# The proxy is pinned to the tested release below. Set
# AI_SANDBOX_MCP_AUTH_PROXY_BIN to reuse a local binary; the script warns when
# that binary is not the pinned build.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
proxy_a_pid=""
proxy_b_pid=""
upstream_a_pid=""
upstream_b_pid=""
cleanup() {
  for pid in "$proxy_a_pid" "$proxy_b_pid" "$upstream_a_pid" "$upstream_b_pid"; do
    [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
  done
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 is required for the proof upstream"
command -v openssl >/dev/null 2>&1 || fail "openssl is required to sign audience-proof tokens"

# --- pinned proxy binary -----------------------------------------------------

proxy_version="v2.10.2"
pinned_amd64="1c76b230fdb6c536a0912c059232cba2229acbcf1f02a11a5d0664781326bcd6"
pinned_arm64="924c5335e5f684eb22c681cca1daff86d96fa35f644950cbd8f4c8f3e290bc3d"
case "$(uname -m)" in
  x86_64)
    proxy_asset="linux-amd64"
    proxy_checksum="$pinned_amd64"
    ;;
  aarch64|arm64)
    proxy_asset="linux-arm64"
    proxy_checksum="$pinned_arm64"
    ;;
  *)
    fail "unsupported architecture for the OAuth proxy proof: $(uname -m)"
    ;;
esac

proxy_bin="${AI_SANDBOX_MCP_AUTH_PROXY_BIN:-}"
if [[ -z "$proxy_bin" ]]; then
  proxy_bin="$test_root/mcp-auth-proxy"
  curl -fL --silent --show-error \
    "https://github.com/sigbit/mcp-auth-proxy/releases/download/$proxy_version/mcp-auth-proxy-$proxy_asset" \
    -o "$proxy_bin"
  printf '%s  %s\n' "$proxy_checksum" "$proxy_bin" | sha256sum -c - >/dev/null ||
    fail "downloaded proxy checksum mismatch"
  chmod 0755 "$proxy_bin"
else
  supplied_hash="$(sha256sum "$proxy_bin" | awk '{print $1}')"
  case "$supplied_hash" in
    "$proxy_checksum")
      echo "using pinned mcp-auth-proxy $proxy_version ($proxy_asset)"
      ;;
    "$pinned_amd64"|"$pinned_arm64")
      echo "using pinned mcp-auth-proxy $proxy_version (binary from another architecture)"
      ;;
    *)
      echo "WARN: AI_SANDBOX_MCP_AUTH_PROXY_BIN is not the pinned $proxy_version build;" >&2
      echo "WARN: the version pin assertion is bypassed for this run." >&2
      ;;
  esac
fi
[[ -x "$proxy_bin" ]] || fail "OAuth proxy binary is not executable: $proxy_bin"

# --- fixtures ----------------------------------------------------------------

cat >"$test_root/upstream.py" <<'PYEOF'
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

name = sys.argv[1]
port = int(sys.argv[2])
log_path = sys.argv[3]
expected = sys.argv[4]


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
            }) + "\n")

    def send_json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_request(self):
        self.record()
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if self.headers.get("Authorization") != "Bearer " + expected:
            self.send_json(401, {"error": "unauthorized_upstream"})
            return
        try:
            message = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self.send_json(400, {"error": "bad_json"})
            return
        if message.get("method") == "initialize":
            self.send_json(200, {
                "jsonrpc": "2.0", "id": message.get("id"),
                "result": {"protocolVersion": "2025-06-18",
                           "serverInfo": {"name": name, "version": "0.1.0"}},
            })
            return
        self.send_json(200, {
            "jsonrpc": "2.0", "id": message.get("id"),
            "result": {"server": name},
        })

    def do_GET(self):
        self.record()
        if self.headers.get("Authorization") != "Bearer " + expected:
            self.send_json(401, {"error": "unauthorized_upstream"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for index in range(3):
            chunk = ("data: chunk-%d from %s\n\n" % (index, name)).encode()
            self.wfile.write(("%x\r\n" % len(chunk)).encode() + chunk + b"\r\n")
            self.wfile.flush()
            time.sleep(0.05)
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    do_POST = handle_request
    do_DELETE = handle_request


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
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

start_upstream() {
  local name="$1" port="$2" log="$3"
  : >"$log"
  python3 "$test_root/upstream.py" "$name" "$port" "$log" "internal-secret-$name" \
    >/dev/null 2>&1 &
  echo $!
}

wait_for_proxy() {
  local base="$1"
  for _ in {1..60}; do
    if curl -s -o /dev/null "$base/.well-known/oauth-protected-resource"; then
      return 0
    fi
    sleep 0.1
  done
  fail "OAuth proxy did not become ready: $base"
}

# Secrets are passed through the environment (supported by the proxy), never
# through process arguments.
start_proxy() {
  local port="$1" data_path="$2" upstream_port="$3" suffix="$4" log="$5"
  PASSWORD="proof-password" \
    PROXY_BEARER_TOKEN="internal-secret-upstream-$suffix" \
    "$proxy_bin" \
    --listen "127.0.0.1:$port" \
    --external-url "http://127.0.0.1:$port" \
    --no-auto-tls \
    --data-path "$data_path" \
    -- "http://127.0.0.1:$upstream_port" >"$log" 2>&1 &
  echo $!
}

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

b64url_decode() {
  local value="$1"
  value="${value//-/+}"
  value="${value//_//}"
  case $((${#value} % 4)) in
    2) value="$value==" ;;
    3) value="$value=" ;;
  esac
  printf '%s' "$value" | base64 -d
}

# Build an RS256 token with the given key, reusing claims from a real token and
# overriding only issuer/audience. Used to prove audience enforcement.
craft_token() {
  local private_key="$1" real_token="$2" issuer="$3" audience="$4"
  local header payload encoded_header encoded_payload signature
  header='{"alg":"RS256","typ":"JWT"}'
  payload="$(b64url_decode "$(cut -d. -f2 <<<"$real_token")" |
    jq -c --arg issuer "$issuer" --arg audience "$audience" \
      '.iss = $issuer | .aud = [$audience]')"
  encoded_header="$(printf '%s' "$header" | b64url)"
  encoded_payload="$(printf '%s' "$payload" | b64url)"
  signature="$(printf '%s.%s' "$encoded_header" "$encoded_payload" |
    openssl dgst -sha256 -sign "$private_key" | b64url)"
  printf '%s.%s.%s\n' "$encoded_header" "$encoded_payload" "$signature"
}

# password + PKCE flow, including the resource parameter on both the
# authorization request and the token exchange, as ChatGPT sends it.
run_oauth_flow() {
  local base="$1" cookie_jar="$2"
  local redirect='https://chatgpt.com/connector/oauth/proof'
  local verifier='dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
  local challenge='E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM'
  local resource="$base/"
  local client_id loc final code

  client_id="$(curl -s -X POST "$base/.idp/register" -H 'Content-Type: application/json' \
    -d "{\"redirect_uris\":[\"$redirect\"],\"client_name\":\"proof\",\"token_endpoint_auth_method\":\"none\",\"grant_types\":[\"authorization_code\",\"refresh_token\"],\"response_types\":[\"code\"]}" |
    jq -r '.client_id // empty')"
  [[ -n "$client_id" ]] || fail "dynamic client registration returned no client_id"
  printf '%s\n' "$client_id" >"$cookie_jar.client"

  rm -f "$cookie_jar"
  loc="$(curl -s -i -c "$cookie_jar" -b "$cookie_jar" --max-redirs 0 \
    "$base/.idp/auth?response_type=code&client_id=$client_id&redirect_uri=https%3A%2F%2Fchatgpt.com%2Fconnector%2Foauth%2Fproof&code_challenge=$challenge&code_challenge_method=S256&state=proof-state&resource=$resource" |
    awk 'tolower($1) == "location:" { print $2 }' | tr -d '\r')"
  case "$loc" in /*) loc="$base$loc" ;; esac
  curl -s -o /dev/null -c "$cookie_jar" -b "$cookie_jar" --max-redirs 0 "$loc"

  loc="$(curl -s -i -b "$cookie_jar" -c "$cookie_jar" -X POST "$base/.auth/login" \
    --data-urlencode "password=proof-password" |
    awk 'tolower($1) == "location:" { print $2 }' | tr -d '\r')"
  [[ -n "$loc" ]] || fail "password login did not redirect"
  case "$loc" in /*) loc="$base$loc" ;; esac

  final="$(curl -s -i -b "$cookie_jar" -c "$cookie_jar" -X POST "$loc" |
    awk 'tolower($1) == "location:" { print $2 }' | tr -d '\r')"
  code="$(printf '%s' "$final" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
  [[ -n "$code" ]] || fail "consent step returned no authorization code"

  curl -s -X POST "$base/.idp/token" \
    -d grant_type=authorization_code -d "code=$code" -d "client_id=$client_id" \
    --data-urlencode "redirect_uri=$redirect" -d "code_verifier=$verifier" \
    -d "resource=$resource"
}

# --- one-workspace proof -----------------------------------------------------

port_upstream_a="$(pick_port)"
port_upstream_b="$(pick_port)"
port_proxy_a="$(pick_port)"
port_proxy_b="$(pick_port)"
base_a="http://127.0.0.1:$port_proxy_a"
base_b="http://127.0.0.1:$port_proxy_b"
state_a="$test_root/state-a"
state_b="$test_root/state-b"
mkdir -p "$state_a" "$state_b"
chmod 0700 "$state_a" "$state_b"

upstream_a_pid="$(start_upstream upstream-a "$port_upstream_a" "$test_root/upstream-a.jsonl")"
sleep 0.3
proxy_a_pid="$(start_proxy "$port_proxy_a" "$state_a/data" "$port_upstream_a" a "$test_root/proxy-a.log")"
wait_for_proxy "$base_a"

echo "== discovery"
curl -s "$base_a/.well-known/oauth-protected-resource" >"$test_root/prm.json"
jq -e --arg url "$base_a/" '.resource == $url and (.authorization_servers | length) >= 1' \
  "$test_root/prm.json" >/dev/null || fail "protected resource metadata is incomplete"
if ! curl -sf -o /dev/null "$base_a/.well-known/oauth-protected-resource/mcp"; then
  echo "WARN: path-suffixed protected resource metadata is not served (upstream issue #177)"
fi
curl -s "$base_a/.well-known/oauth-authorization-server" >"$test_root/as.json"
jq -e --arg issuer "$base_a/" \
  '.issuer == $issuer and (.registration_endpoint | length) > 0 and
   (.code_challenge_methods_supported | index("S256") != null) and
   (.grant_types_supported | index("refresh_token") != null)' \
  "$test_root/as.json" >/dev/null || fail "authorization server metadata is incomplete"

echo "== unauthenticated challenge"
unauth_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base_a/mcp" \
  -H 'Content-Type: application/json' -d '{}')"
[[ "$unauth_code" == 401 ]] || fail "unauthenticated MCP request returned $unauth_code"

echo "== PKCE flow, resource parameter, and audience binding"
token_json="$(run_oauth_flow "$base_a" "$test_root/cookies-a.txt")"
access="$(jq -r '.access_token // empty' <<<"$token_json")"
refresh="$(jq -r '.refresh_token // empty' <<<"$token_json")"
[[ -n "$access" && -n "$refresh" ]] || fail "token response is missing access/refresh tokens"
audience="$(b64url_decode "$(cut -d. -f2 <<<"$access")" | jq -r '.aud[0] // empty')"
[[ "$audience" == "$base_a/" ]] || fail "token audience is '$audience', expected '$base_a/'"

echo "== proxy secrets are not in process arguments"
ps -o args= -p "$proxy_a_pid" >"$test_root/proxy-a-args"
rg -q -F 'proof-password' "$test_root/proxy-a-args" &&
  fail "proxy password is visible in process arguments"
rg -q -F 'internal-secret-upstream-a' "$test_root/proxy-a-args" &&
  fail "upstream bearer is visible in process arguments"

echo "== upstream bearer injection and path mapping"
curl -s -X POST "$base_a/mcp" -H "Authorization: Bearer $access" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}' >"$test_root/initialize.json"
jq -e '.result.serverInfo.name == "upstream-a"' "$test_root/initialize.json" >/dev/null ||
  fail "authenticated initialize did not reach upstream A"
first_call="$(head -1 "$test_root/upstream-a.jsonl")"
jq -e --arg auth "Bearer internal-secret-upstream-a" \
  '.authorization == $auth and .path == "/mcp"' <<<"$first_call" >/dev/null ||
  fail "upstream did not receive the injected bearer on /mcp"
if rg -q -F "$access" "$test_root/upstream-a.jsonl"; then
  fail "OAuth access token leaked to the upstream"
fi

echo "== session headers and SSE passthrough"
curl -s -X POST "$base_a/mcp" -H "Authorization: Bearer $access" \
  -H 'Content-Type: application/json' -H 'Mcp-Session-Id: proof-session' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' >/dev/null
jq -e '.session == "proof-session"' <<<"$(tail -1 "$test_root/upstream-a.jsonl")" >/dev/null ||
  fail "Mcp-Session-Id was not forwarded"
curl -s -N -H "Authorization: Bearer $access" "$base_a/mcp" >"$test_root/stream.txt" || true
rg -q 'data: chunk-0 from upstream-a' "$test_root/stream.txt" ||
  fail "SSE passthrough failed"

echo "== audience enforcement with a shared trusted key"
# Endpoint B trusts the same signing key as A, so signature checks cannot
# explain a rejection; only issuer/audience claims can.
mkdir -p "$state_b/data"
cp "$state_a/data/private_key.pem" "$state_b/data/private_key.pem"
chmod 0600 "$state_b/data/private_key.pem"
upstream_b_pid="$(start_upstream upstream-b "$port_upstream_b" "$test_root/upstream-b.jsonl")"
sleep 0.3
proxy_b_pid="$(start_proxy "$port_proxy_b" "$state_b/data" "$port_upstream_b" b "$test_root/proxy-b.log")"
wait_for_proxy "$base_b"

real_cross="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base_b/mcp" \
  -H "Authorization: Bearer $access" -H 'Content-Type: application/json' -d '{}')"
[[ "$real_cross" == 401 ]] ||
  fail "token for endpoint A was accepted by endpoint B ($real_cross)"

wrong_aud="$(craft_token "$state_a/data/private_key.pem" "$access" "$base_b/" "$base_a/")"
wrong_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base_b/mcp" \
  -H "Authorization: Bearer $wrong_aud" -H 'Content-Type: application/json' -d '{}')"
[[ "$wrong_code" == 401 ]] ||
  fail "token with wrong audience was accepted by endpoint B ($wrong_code)"

right_aud="$(craft_token "$state_a/data/private_key.pem" "$access" "$base_b/" "$base_b/")"
right_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base_b/mcp" \
  -H "Authorization: Bearer $right_aud" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}')"
[[ "$right_code" == 200 ]] ||
  fail "control token with matching audience and shared key was rejected ($right_code)"
jq -e --arg auth "Bearer internal-secret-upstream-b" \
  '.authorization == $auth' <<<"$(tail -1 "$test_root/upstream-b.jsonl")" >/dev/null ||
  fail "endpoint B did not inject its own upstream bearer"

echo "== restart keeps registrations and refresh tokens"
kill "$proxy_a_pid"
wait "$proxy_a_pid" 2>/dev/null || true
proxy_a_pid="$(start_proxy "$port_proxy_a" "$state_a/data" "$port_upstream_a" a "$test_root/proxy-a.log")"
wait_for_proxy "$base_a"
client_id="$(<"$test_root/cookies-a.txt.client")"
refreshed="$(curl -s -X POST "$base_a/.idp/token" -d grant_type=refresh_token \
  -d "refresh_token=$refresh" -d "client_id=$client_id")"
jq -e '(.access_token | length) > 0' <<<"$refreshed" >/dev/null ||
  fail "refresh token did not survive a proxy restart"

echo "== proxy state permissions and layout"
for expected in private_key.pem secret db; do
  [[ -f "$state_a/data/$expected" ]] ||
    fail "expected proxy state file is missing: $expected"
done
[[ "$(stat -c %a "$state_a")" == 700 ]] ||
  fail "state wrapper directory is not 0700"
while IFS= read -r file; do
  mode="$(stat -c %a "$file")"
  [[ "$mode" == 600 ]] || fail "$(basename "$file") has mode $mode, expected 600"
done < <(find "$state_a/data" -type f)

echo "MCP OAuth proxy proof passed"
