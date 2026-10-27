#!/usr/bin/env bash
# End-to-end smoke tests for the standalone stack. Requires Docker and curl.
#
# Builds and starts the stack (waiting on health checks, not sleeps), runs
# routing, header, failure and exposure checks, restarts the stack, and leaves
# it running. Pass --down to stop it afterwards.
#
#   ./scripts/smoke-test.sh [--down]
set -uo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
HOST_SVC_PID=""
cleanup() {
  # Remove routes the add-route test may have left behind if the run aborted.
  for h in smoke-container.local.test smoke-host.local.test smoke-ui.local.test; do
    grep -qF "# --- add-route: $h ---" envoy/envoy.yaml && ./scripts/add-route.sh --remove "$h" --no-restart >/dev/null 2>&1
  done
  [[ -n "$HOST_SVC_PID" ]] && kill "$HOST_SVC_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }
section() { printf '\n== %s\n' "$1"; }

# check "description" command...   (passes when the command succeeds)
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc" "status=$STATUS body=$(head -c 300 <<<"$BODY" | tr '\n' ' ')"; fi; }

# request HOST PATH [curl args...]  -> sets STATUS, BODY, HEADERS, REQ_ID
request() {
  local host=$1 path=$2; shift 2
  STATUS=$(curl -sS --max-time 10 -D "$TMP/h" -o "$TMP/b" -w '%{http_code}' \
    -H "Host: $host" "$@" "$BASE$path" 2>/dev/null) || true
  [[ -z "$STATUS" ]] && STATUS=000
  BODY=$(cat "$TMP/b" 2>/dev/null || true)
  HEADERS=$(tr -d '\r' <"$TMP/h" 2>/dev/null || true)
  REQ_ID=$(awk 'tolower($1)=="x-request-id:" {print $2}' <<<"$HEADERS")
}

# app-one (echo) names itself in its JSON; app-two (go-httpbin) reports the URL it received.
served_by() { grep -qF "\"service\": \"$1\"" <<<"$BODY"; }
httpbin_url_is() { grep -qF "\"url\": \"$1\"" <<<"$BODY"; }
upstream_path_is() { grep -qF "\"path\": \"$1\"" <<<"$BODY"; }
status_is() { [[ "$STATUS" == "$1" ]]; }

# access_log_for REQUEST_ID -> prints the access-log line (retries briefly;
# Envoy flushes access logs asynchronously).
access_log_for() {
  local line
  for _ in $(seq 1 20); do
    line=$(docker compose logs --no-log-prefix envoy 2>/dev/null | grep -F "request_id=$1" | tail -1)
    [[ -n "$line" ]] && { echo "$line"; return 0; }
    sleep 0.5
  done
  return 1
}

# wait_for_status HOST PATH STATUS TIMEOUT_SECONDS
wait_for_status() {
  local deadline=$((SECONDS + $4))
  while ((SECONDS < deadline)); do
    request "$1" "$2"
    status_is "$3" && return 0
    sleep 1
  done
  return 1
}

start_stack() {
  # --remove-orphans also drops the forwarder left by compose.admin.yaml, if any.
  docker compose up -d --build --wait --wait-timeout 90 --remove-orphans >"$TMP/up.log" 2>&1 || { cat "$TMP/up.log"; return 1; }
  BASE="http://$(docker compose port envoy 10000)"
}

# ---------------------------------------------------------------------------
section "1-2. Configuration validation and startup"
if ./scripts/validate.sh >"$TMP/validate.log" 2>&1; then pass "compose and Envoy configuration validate"; else fail "configuration validation" "$(cat "$TMP/validate.log")"; fi

if start_stack; then
  pass "stack started; health checks passed (listener at $BASE)"
else
  fail "stack failed to start"
  docker compose ps
  docker compose logs --tail 30 envoy
  exit 1
fi
STATUS=-; BODY=-
check "Envoy container reports healthy" test "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q envoy)")" = healthy

# ---------------------------------------------------------------------------
section "3-5. Hostname routing"
request app-one.local.test /
check "app-one.local.test / -> backend app-one" eval 'status_is 200 && served_by app-one'
request app-two.local.test /
check "app-two.local.test / -> backend app-two (httpbin)" eval 'status_is 200 && grep -q "go-httpbin" <<<"$BODY"'
check "same path, different hosts reach different backends" eval '! grep -qF "\"service\"" <<<"$BODY"'
request app-one.local.test:8080 /
check "Host header with a port still matches (port is stripped)" eval 'status_is 200 && served_by app-one && grep -qF "\"host\": \"app-one.local.test\"" <<<"$BODY"'

# ---------------------------------------------------------------------------
section "6. Path-prefix routing"
request app-one.local.test /status/418
check "app-one.local.test/status/418 -> backend app-two (httpbin returns 418)" status_is 418
request app-one.local.test /statuses
check "/statuses is not matched by the /status prefix (segment matching)" eval 'status_is 200 && served_by app-one && upstream_path_is /statuses'

# ---------------------------------------------------------------------------
section "7. Path rewriting"
request app-two.local.test '/api/items?page=2'
check "/api/items?page=2 is rewritten to /anything/items?page=2" eval 'status_is 200 && httpbin_url_is "http://app-two.local.test/anything/items?page=2"'
request app-two.local.test /api
check "/api is rewritten to /anything" eval 'status_is 200 && httpbin_url_is "http://app-two.local.test/anything"'

# ---------------------------------------------------------------------------
section "Timeouts"
request app-two.local.test /delay/1
check "/delay/1 finishes within the 3s route timeout -> 200" status_is 200
start=$SECONDS
request app-two.local.test /delay/5
elapsed=$((SECONDS - start))
check "/delay/5 exceeds the 3s route timeout -> 504 after ~3s (took ${elapsed}s)" eval 'status_is 504 && ((elapsed < 5))'
log=$(access_log_for "$REQ_ID" || true)
check "504 is logged with flags=UT details=response_timeout" eval 'grep -q "status=504 flags=UT details=response_timeout" <<<"$log"'

# ---------------------------------------------------------------------------
section "8-9. Unknown hosts and paths"
request unknown.local.test /
check "unknown host -> 404" status_is 404
log=$(access_log_for "$REQ_ID" || true)
check "unknown host is logged with flags=NR details=route_not_found" eval 'grep -q "flags=NR details=route_not_found" <<<"$log"'
request app-two.local.test /does-not-exist
check "unknown path on app-two.local.test -> 404" status_is 404
request app-two.local.test /apix
check "/apix -> 404 (not matched by the /api prefix)" status_is 404

# ---------------------------------------------------------------------------
section "Request headers"
request app-one.local.test /headers -H 'X-Forwarded-For: 203.0.113.9' -H 'X-Forwarded-Proto: https' -H 'X-Envoy-External-Address: 203.0.113.9'
peer=$(awk -F'"' '/"x-envoy-external-address"/ {print $4}' <<<"$BODY")
check "Host header is preserved upstream" grep -qF '"host": "app-one.local.test"' <<<"$BODY"
check "client X-Forwarded-For is kept and the real peer ($peer) appended" grep -qF "\"x-forwarded-for\": \"203.0.113.9,$peer\"" <<<"$BODY"
check "spoofed X-Envoy-External-Address is replaced with the peer" eval '[[ -n "$peer" && "$peer" != 203.0.113.9 ]]'
check "client X-Forwarded-Proto is overwritten with the real scheme (http)" grep -qF '"x-forwarded-proto": "http"' <<<"$BODY"
check "x-request-id is returned to the client" test -n "$REQ_ID"
check "no x-envoy-* response headers (suppress_envoy_headers)" eval '! grep -qi "^x-envoy-" <<<"$HEADERS"'
# Without X-Forwarded-For, Envoy decides "internal vs external" from the peer
# address alone; the Docker gateway (RFC1918) must still count as external.
request app-one.local.test /headers -H 'X-Envoy-External-Address: 203.0.113.9' -H 'X-Envoy-Internal: true'
check "without XFF: spoofed X-Envoy-External-Address is still replaced" eval '! grep -qF "203.0.113.9" <<<"$BODY"'
check "without XFF: request is not marked x-envoy-internal" eval '! grep -qF "\"x-envoy-internal\"" <<<"$BODY"'

# ---------------------------------------------------------------------------
section "WebSocket upgrade"
request app-one.local.test /ws --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='
check "WebSocket handshake through Envoy -> 101" status_is 101

# ---------------------------------------------------------------------------
section "10. Unavailable backend"
docker compose stop sample-app-two >/dev/null 2>&1
if wait_for_status app-two.local.test / 503 30; then
  pass "stopped backend -> 503"
  log=$(access_log_for "$REQ_ID" || true)
  check "503 is logged with an upstream failure flag (UF/UH) and details" eval 'grep -Eq "status=503 flags=(UF|UH|URX)[^ ]* details=[a-z_]+" <<<"$log"'
  check "response carries x-request-id for log correlation" test -n "$REQ_ID"
  printf '       log: %s\n' "$(cut -c1-220 <<<"$log")"
else
  fail "stopped backend did not produce 503 within 30s" "last status=$STATUS"
fi
request app-one.local.test /
check "other backend unaffected while app-two is down" eval 'status_is 200 && served_by app-one'
docker compose start sample-app-two >/dev/null 2>&1
if wait_for_status app-two.local.test / 200 30; then pass "app-two recovers after restart (DNS re-resolved)"; else fail "app-two did not recover within 30s"; fi

# ---------------------------------------------------------------------------
section "11. Admin interface is not exposed"
STATUS=-; BODY=-
check "admin port 9901 is not published" eval '! docker compose port envoy 9901 >/dev/null 2>&1'
check "only the HTTP listener is published" test "$(docker port "$(docker compose ps -q envoy)" | wc -l | tr -d ' ')" = 1
check "admin is unreachable over TCP from another container on the network" \
  eval '! docker compose exec -T sample-app-one python -c "import socket; socket.create_connection((\"envoy\", 9901), timeout=3)" >/dev/null 2>&1'
check "admin answers on its Unix socket (diagnostics still work)" eval '[[ "$(./scripts/admin.sh /ready)" == LIVE* ]]'

# ---------------------------------------------------------------------------
section "add-route.sh"
STATUS=-; BODY=-
if ./scripts/add-route.sh smoke-container.local.test container:sample-app-one:8000 >"$TMP/ar.log" 2>&1; then
  request smoke-container.local.test /
  check "route added to a container (container:NAME:PORT) works" eval 'status_is 200 && served_by app-one'
else
  fail "add-route.sh container target" "$(tail -3 "$TMP/ar.log")"
fi
# A second path on the same hostname, to another app, with a prefix rewrite.
# It is added after "/", so this also proves the script orders routes.
if ./scripts/add-route.sh smoke-container.local.test container:sample-app-two:8080 --path /api --rewrite / >"$TMP/ar.log" 2>&1; then
  request smoke-container.local.test '/api/anything?x=1'
  check "--path /api --rewrite /: /api/anything -> app-two as /anything" eval 'status_is 200 && httpbin_url_is "http://smoke-container.local.test/anything?x=1"'
  request smoke-container.local.test /apix
  check "/apix still goes to the / route (segment-aware prefix)" eval 'status_is 200 && served_by app-one'
else
  fail "add-route.sh --path/--rewrite" "$(tail -3 "$TMP/ar.log")"
fi
./scripts/add-route.sh --remove smoke-container.local.test --path /api >/dev/null 2>&1
request smoke-container.local.test /api/anything
check "--remove --path /api: /api/… falls back to the / route" eval 'status_is 200 && served_by app-one && upstream_path_is /api/anything'

# A throwaway HTTP service on this machine, bound to loopback only.
if command -v python3 >/dev/null; then
  python3 -m http.server 18765 --bind 127.0.0.1 --directory "$TMP" >/dev/null 2>&1 &
  HOST_SVC_PID=$!
  if ./scripts/add-route.sh smoke-host.local.test host:18765 >"$TMP/ar.log" 2>&1; then
    request smoke-host.local.test /
    check "route added to a service on this machine (host:PORT) works" eval 'status_is 200 && grep -q "Directory listing" <<<"$BODY"'
  else
    fail "add-route.sh host target" "$(tail -3 "$TMP/ar.log")"
  fi
  ./scripts/add-route.sh --remove smoke-host.local.test --no-restart >/dev/null 2>&1
else
  printf '  SKIP host:PORT target (python3 not installed)\n'
fi

./scripts/add-route.sh --remove smoke-container.local.test >/dev/null 2>&1
request smoke-container.local.test /
check "removed route -> 404 again" status_is 404

# ---------------------------------------------------------------------------
section "routes-ui (web UI)"
UI="http://$(docker compose port routes-ui 8090)"
ui() { curl -sS --max-time 60 -H 'Content-Type: application/json' "$@" 2>/dev/null; }
STATUS=-; BODY=$(ui "$UI/api/routes")
check "UI lists the configured hostnames" grep -qF '"host": "app-one.local.test"' <<<"$BODY"
BODY=$(ui -X POST -d '{"host":"smoke-ui.local.test","kind":"container","name":"sample-app-one","port":8000}' "$UI/api/routes")
check "UI adds a route (runs add-route.sh in the container)" grep -qF '"ok": true' <<<"$BODY"
request smoke-ui.local.test /
check "route added from the UI serves traffic" eval 'status_is 200 && served_by app-one'
BODY=$(ui -X POST -d '{"host":"smoke-ui.local.test","kind":"container","name":"sample-app-two","port":8080,"path":"/api","rewrite":"/"}' "$UI/api/routes")
request smoke-ui.local.test /api/anything
check "UI adds a second path with a rewrite" eval 'status_is 200 && httpbin_url_is "http://smoke-ui.local.test/anything"'
BODY=$(ui -X DELETE "$UI/api/routes/smoke-ui.local.test?path=/api")
request smoke-ui.local.test /api/anything
check "UI removes one route of a hostname" eval 'status_is 200 && served_by app-one'
BODY=$(ui -X DELETE "$UI/api/routes/smoke-ui.local.test")
check "UI removes the hostname" grep -qF '"ok": true' <<<"$BODY"
request smoke-ui.local.test /
check "removed hostname -> 404 again" status_is 404
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://evil.test' -H 'Content-Type: application/json' -d '{}' "$UI/api/routes")
check "UI rejects cross-origin changes (403)" status_is 403
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.test' "$UI/api/routes")
check "UI rejects foreign Host headers (403)" status_is 403

# ---------------------------------------------------------------------------
section "12. Stop and restart"
if docker compose down >/dev/null 2>&1 && start_stack; then
  request app-one.local.test /
  check "after down + up, routing works again" eval 'status_is 200 && served_by app-one'
else
  fail "stack did not restart"
fi

# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--down" ]]; then docker compose down >/dev/null 2>&1; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
