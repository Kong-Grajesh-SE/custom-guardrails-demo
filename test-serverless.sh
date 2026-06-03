#!/usr/bin/env bash
# =============================================================================
# test-serverless.sh — MCP + guardrail-service PDP demo against Konnect Serverless
#
# Usage:
#   ./test-serverless.sh              # all tests
#   ./test-serverless.sh local        # local services only (MCP + guardrail-service direct)
#   ./test-serverless.sh kong         # Konnect end-to-end only
#
# Environment:
#   KONNECT_PROXY_URL   default: from .env
#   MCP_URL             default: http://localhost:8092
#   GUARDRAIL_URL      default: http://localhost:8089
# =============================================================================
set -euo pipefail

# Load .env if present
[[ -f .env ]] && { set -o allexport; source .env; set +o allexport; }

KONNECT_PROXY="${KONNECT_PROXY_URL:-}"
MCP_URL="${MCP_URL:-http://localhost:8092}"
GUARDRAIL_URL="${GUARDRAIL_URL:-http://localhost:8089}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

pass()    { echo -e "${GREEN}  ✓ PASS${NC}  $1"; }
fail()    { echo -e "${RED}  ✗ FAIL${NC}  $1"; FAILURES=$((FAILURES+1)); }
info()    { echo -e "${BLUE}  ▶${NC}  $1"; }
section() {
  echo ""
  echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  $1${NC}"
  echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
}

FAILURES=0

pretty() { python3 -m json.tool 2>/dev/null || cat; }

# ── MCP JSON-RPC helpers ──────────────────────────────────────────────────────

mcp_call() {
  local base_url="$1" method="$2" tool="$3"
  local body
  if [[ -n "$tool" ]]; then
    body="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":{\"name\":\"$tool\"}}"
  else
    body="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":{}}"
  fi
  curl -s -w "\n__HTTP_STATUS__:%{http_code}" \
    -X POST "$base_url" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    --data "$body"
}

split_response() {
  local raw="$1"
  RESP_BODY=$(echo "$raw" | grep -v "__HTTP_STATUS__")
  RESP_STATUS=$(echo "$raw" | grep "__HTTP_STATUS__" | cut -d: -f2)
}

# ═════════════════════════════════════════════════════════════════════════════
# Section 1: Local MCP Server (direct, no Kong)
# ═════════════════════════════════════════════════════════════════════════════
test_local_mcp() {
  section "1 · MCP Server — Direct (no Kong)"
  echo -e "  ${CYAN}$MCP_URL${NC}"

  info "Health check"
  h=$(curl -s "$MCP_URL/health")
  echo "  $h"
  if echo "$h" | grep -q '"ok"'; then pass "MCP server healthy"; else fail "MCP server unhealthy"; return; fi

  info "initialize"
  raw=$(mcp_call "$MCP_URL" "initialize" "")
  split_response "$raw"
  echo "  $(echo "$RESP_BODY" | pretty)"
  echo "$RESP_BODY" | grep -q '"protocolVersion"' && pass "initialize returns server info" || fail "initialize failed"

  info "tools/list"
  raw=$(mcp_call "$MCP_URL" "tools/list" "")
  split_response "$raw"
  echo "$RESP_BODY" | grep -q '"get_weather"' && pass "tools/list returns catalogue" || fail "tools/list failed"

  info "tools/call  get_weather(city=Sydney)"
  raw=$(curl -s -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_weather","arguments":{"city":"Sydney"}}}')
  echo "  $(echo "$raw" | pretty)"
  echo "$raw" | grep -qi "sydney" && pass "get_weather returned weather data" || fail "get_weather failed"

  info "tools/call  calculator(expression='(3+5)*2')"
  raw=$(curl -s -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"calculator","arguments":{"expression":"(3+5)*2"}}}')
  echo "  $(echo "$raw" | pretty)"
  echo "$raw" | grep -q "16" && pass "calculator returned correct result" || fail "calculator failed"

  info "tools/call  search_docs(query=kong)"
  raw=$(curl -s -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_docs","arguments":{"query":"kong"}}}')
  echo "$raw" | grep -qi "kong" && pass "search_docs returned results" || fail "search_docs failed"

  info "tools/call  execute_shell — server-side guard (should return error, NOT execute)"
  raw=$(curl -s -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"execute_shell","arguments":{"cmd":"ls"}}}')
  echo "  $(echo "$raw" | pretty)"
  echo "$raw" | grep -q '"error"' && pass "execute_shell rejected by server guard" || fail "execute_shell was NOT rejected"
}

# ═════════════════════════════════════════════════════════════════════════════
# Section 2: Guardrail Service PDP Direct Tests
# ═════════════════════════════════════════════════════════════════════════════
test_local_opa() {
  section "2 · Guardrail Service PDP — Direct"
  echo -e "  ${CYAN}$GUARDRAIL_URL/v1/data/mcp/authz/allow${NC}"

  info "Health check"
  h=$(curl -s "$GUARDRAIL_URL/health")
  echo "  $h"
  if echo "$h" | grep -qE '"ok"|true'; then pass "Guardrail service healthy"; else fail "Guardrail service unhealthy"; return; fi

  opa_query() {
    local method="$1" tool="$2"
    local parsed_body
    if [[ -n "$tool" ]]; then
      parsed_body="{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":{\"name\":\"$tool\"}}"
    else
      parsed_body="{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":{}}"
    fi
    # Match the structure Kong OPA plugin sends: input.request.http.parsed_body
    curl -s -X POST "$GUARDRAIL_URL/v1/data/mcp/authz/allow" \
      -H "Content-Type: application/json" \
      --data "{\"input\":{\"request\":{\"http\":{\"parsed_body\":$parsed_body}}}}"
  }

  info "tools/list → expect allow=true"
  r=$(opa_query "tools/list" ""); echo "  $r"
  echo "$r" | grep -qE '"result":\s*true' && pass "tools/list allowed" || fail "tools/list denied"

  info "initialize → expect allow=true"
  r=$(opa_query "initialize" "")
  echo "$r" | grep -qE '"result":\s*true' && pass "initialize allowed" || fail "initialize denied"

  info "tools/call  get_weather → expect allow=true"
  r=$(opa_query "tools/call" "get_weather")
  echo "$r" | grep -qE '"result":\s*true' && pass "get_weather allowed" || fail "get_weather denied"

  info "tools/call  execute_shell → expect allow=false (DENY)"
  r=$(opa_query "tools/call" "execute_shell"); echo "  $r"
  echo "$r" | grep -qE '"result":\s*false|^\{\}$' && pass "execute_shell DENIED by policy" || fail "execute_shell NOT denied"

  info "tools/call  admin_reset → expect allow=false (DENY)"
  r=$(opa_query "tools/call" "admin_reset"); echo "  $r"
  echo "$r" | grep -qE '"result":\s*false|^\{\}$' && pass "admin_reset DENIED by policy" || fail "admin_reset NOT denied"

  info "unknown_method → expect allow=false (DENY)"
  r=$(opa_query "evil_method" ""); echo "  $r"
  echo "$r" | grep -qE '"result":\s*false|^\{\}$' && pass "unknown method DENIED by policy" || fail "unknown method NOT denied"

  info "tools/call  calc with dangerous arg (rm -rf /) → expect DENY"
  r=$(curl -s -X POST "$GUARDRAIL_URL/v1/data/mcp/authz/allow" \
    -H "Content-Type: application/json" \
    --data '{"input":{"request":{"http":{"parsed_body":{"jsonrpc":"2.0","method":"tools/call","params":{"name":"calculator","arguments":{"expression":"rm -rf /"}}}}}}}')
  echo "  $r"
  echo "$r" | grep -qE '"result":\s*false|^\{\}$' && pass "dangerous arg DENIED by policy" || fail "dangerous arg NOT denied"
}

# ═════════════════════════════════════════════════════════════════════════════
# Section 3: Konnect Serverless End-to-End Tests
# ═════════════════════════════════════════════════════════════════════════════
test_konnect() {
  section "3 · Konnect Serverless — End-to-End"

  if [[ -z "$KONNECT_PROXY" ]]; then
    echo -e "  ${YELLOW}⚠  KONNECT_PROXY_URL not set in .env — skipping Konnect tests.${NC}"
    return
  fi

  local mcp_endpoint="$KONNECT_PROXY/mcp"
  echo -e "  ${CYAN}$mcp_endpoint${NC}"

  check_konnect() {
    local label="$1" method="$2" tool="$3" expected_status="$4"
    local raw status body
    raw=$(mcp_call "$mcp_endpoint" "$method" "$tool")
    split_response "$raw"
    status="$RESP_STATUS"
    body="$RESP_BODY"
    if [[ "$status" == "$expected_status" ]]; then
      pass "[$label]  HTTP $status (expected $expected_status)"
    else
      fail "[$label]  HTTP $status (expected $expected_status)"
      echo "  Body: $(echo "$body" | pretty)"
    fi
  }

  # A — safe operations
  check_konnect "A initialize"    "initialize"  ""            "200"
  check_konnect "B tools/list"    "tools/list"  ""            "200"
  check_konnect "C get_weather"   "tools/call"  "get_weather" "200"
  check_konnect "D calculator"    "tools/call"  "calculator"  "200"
  check_konnect "E search_docs"   "tools/call"  "search_docs" "200"

  # B — OPA blocks dangerous tools
  check_konnect "F execute_shell" "tools/call"  "execute_shell" "403"
  check_konnect "G admin_reset"   "tools/call"  "admin_reset"   "403"
  check_konnect "H write_file"    "tools/call"  "write_file"    "403"
  check_konnect "I drop_database" "tools/call"  "drop_database" "403"

  # C — OPA blocks unknown methods
  check_konnect "J bad_method"    "unknown_xyz" ""              "403"

}

# ═════════════════════════════════════════════════════════════════════════════
# Entry point
# ═════════════════════════════════════════════════════════════════════════════
MODE="${1:-all}"
case "$MODE" in
  local) test_local_mcp; test_local_opa ;;
  kong)  test_konnect ;;
  *)     test_local_mcp; test_local_opa; test_konnect ;;
esac

echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
if (( FAILURES == 0 )); then
  echo -e "${GREEN}  All tests passed.${NC}"
else
  echo -e "${RED}  $FAILURES test(s) failed.${NC}"
fi
echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
echo ""
exit $FAILURES
