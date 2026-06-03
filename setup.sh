#!/usr/bin/env bash
# =============================================================================
# setup.sh — Kong Konnect Serverless MCP + OPA demo
#
# Architecture: MCP Client → Konnect → OPA plugin → ai-mcp-proxy → MCP Server
#               OPA plugin calls guardrail-service as the external PDP
#
# Steps:
#   1. Check prerequisites (docker, ngrok, deck)
#   2. Prompt for Konnect credentials and ngrok authtoken (skips values already in .env)
#   3. Build and start local services (mcp-server + guardrail-service) via Docker
#   4. Open a Terminal window for each ngrok tunnel (MCP server, guardrail-service)
#   5. Auto-detect tunnel URLs from the ngrok local API and write to .env
#   6. Optionally push Kong config to Konnect via deck
#
# Usage:
#   ./setup.sh                 # full setup
#   ./setup.sh --skip-docker   # skip docker compose (already running)
#   ./setup.sh --skip-deck     # skip deck push at the end
#   ./setup.sh --yes           # non-interactive: keep all existing .env values
# =============================================================================
set -euo pipefail

# ── Parse flags ───────────────────────────────────────────────────────────────
SKIP_DOCKER=false
SKIP_DECK=false
YES=false
for arg in "$@"; do
  case "$arg" in
    --skip-docker) SKIP_DOCKER=true ;;
    --skip-deck)   SKIP_DECK=true ;;
    --yes|-y)      YES=true ;;
  esac
done

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

banner()  { echo -e "\n${YELLOW}${BOLD}══════════════════════════════════════════════════${NC}"; echo -e "${YELLOW}${BOLD}  $1${NC}"; echo -e "${YELLOW}${BOLD}══════════════════════════════════════════════════${NC}"; }
step()    { echo -e "\n${BLUE}${BOLD}▶ $1${NC}"; }
ok()      { echo -e "${GREEN}  ✓ $1${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $1${NC}"; }
err()     { echo -e "${RED}  ✗ $1${NC}"; }
info()    { echo -e "  $1"; }

# ── Ensure .env exists ────────────────────────────────────────────────────────
ENV_FILE=".env"
if [[ ! -f "$ENV_FILE" ]]; then
  cp .env.example "$ENV_FILE"
  info "Created $ENV_FILE from .env.example"
fi

# ── .env helpers ──────────────────────────────────────────────────────────────

# Read a value from .env (returns empty string if not set / blank)
env_get() {
  local key="$1"
  local val
  val=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
  # strip surrounding quotes if present
  val="${val%\"}"
  val="${val#\"}"
  echo "$val"
}

# Write or update a key=value in .env
env_set() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    # macOS sed requires '' after -i
    sed -i '' "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

# Interactive prompt — shows current value, uses it if user just presses Enter
# Usage: ask VAR "Label" "default_if_not_in_env" [secret]
ask() {
  local var="$1" label="$2" default="$3" secret="${4:-}"
  local current
  current=$(env_get "$var")
  [[ -z "$current" ]] && current="$default"

  local prompt_str
  if [[ -n "$secret" && -n "$current" ]]; then
    prompt_str="${label} ${CYAN}[current: ***hidden***]${NC}: "
  elif [[ -n "$current" ]]; then
    prompt_str="${label} ${CYAN}[current: ${current}]${NC}: "
  else
    prompt_str="${label}: "
  fi

  local input
  echo -en "  ${prompt_str}"
  # In non-interactive (--yes) mode, keep existing value automatically
  if [[ "$YES" == "true" && -n "$current" ]]; then
    echo "(using existing)"
    input="$current"
  elif [[ -n "$secret" ]]; then
    read -rs input; echo
  else
    read -r input
  fi

  # Keep existing value if user pressed Enter without typing
  [[ -z "$input" ]] && input="$current"

  if [[ -z "$input" ]]; then
    err "$label is required."
    exit 1
  fi

  env_set "$var" "$input"
  # Export into current shell so subsequent steps can use it
  export "$var"="$input"
}

# Same as ask but value is optional (pressing Enter leaves it empty/unchanged)
ask_optional() {
  local var="$1" label="$2" default="$3"
  local current
  current=$(env_get "$var")
  [[ -z "$current" ]] && current="$default"

  local prompt_str
  if [[ -n "$current" ]]; then
    prompt_str="${label} ${CYAN}[current: ${current}]${NC} (Enter to keep): "
  else
    prompt_str="${label} ${CYAN}(optional, Enter to skip)${NC}: "
  fi

  local input
  echo -en "  ${prompt_str}"
  if [[ "$YES" == "true" ]]; then
    echo "(using existing)"
    input="$current"
  else
    read -r input
  fi
  [[ -z "$input" ]] && input="$current"

  env_set "$var" "$input"
  export "$var"="$input"
}

# ── macOS Terminal launcher ───────────────────────────────────────────────────
# Opens a new Terminal.app window and runs a command in it
open_terminal_window() {
  local title="$1" cmd="$2"
  osascript \
    -e 'tell application "Terminal"' \
    -e "  set w to do script \"printf '\\\\033]0;${title}\\\\007'; ${cmd}\"" \
    -e '  activate' \
    -e 'end tell' \
    > /dev/null 2>&1 || true
}

# ── ngrok URL detector ────────────────────────────────────────────────────────
# Polls the ngrok local API to find the public HTTPS URL for a given local addr
# ngrok instances grab API ports sequentially: 4040, 4041, 4042 ...
detect_ngrok_url() {
  local local_port="$1" timeout_secs="${2:-60}"
  local elapsed=0
  echo -n "  Waiting for ngrok tunnel (port ${local_port})" >&2
  while (( elapsed < timeout_secs )); do
    sleep 2
    elapsed=$((elapsed + 2))
    echo -n "." >&2
    # Try each potential ngrok API port (first 3 instances)
    for api_port in 4040 4041 4042 4043; do
      local url
      url=$(curl -s "http://localhost:${api_port}/api/tunnels" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for t in data.get('tunnels', []):
        conf = t.get('config', {})
        addr = conf.get('addr', '')
        pub  = t.get('public_url', '')
        if str(${local_port}) in addr and pub.startswith('https'):
            print(pub)
            break
except:
    pass
" 2>/dev/null || true)
      if [[ -n "$url" ]]; then
        echo " ✓" >&2
        echo "$url"
        return 0
      fi
    done
  done
  echo " timed out" >&2
  return 1
}

# =============================================================================
# STEP 1 — Prerequisites
# =============================================================================
banner "Step 1 · Checking prerequisites"

check_cmd() {
  local cmd="$1" install_hint="$2"
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd found ($(command -v "$cmd"))"
  else
    err "$cmd not found.  $install_hint"
    exit 1
  fi
}

check_cmd docker   "Install Docker Desktop: https://www.docker.com/products/docker-desktop"
check_cmd ngrok    "Install ngrok: brew install ngrok/ngrok/ngrok  or  https://ngrok.com/download"
check_cmd deck     "Install deck: brew install kong/kong/deck"
check_cmd python3  "Install Python 3: brew install python3"

# =============================================================================
# STEP 2 — ngrok authtoken
# =============================================================================
banner "Step 2 · ngrok Authentication"
info "Your ngrok authtoken is at: https://dashboard.ngrok.com/get-started/your-authtoken"

ask NGROK_AUTHTOKEN "ngrok authtoken" "" secret

step "Configuring ngrok authtoken..."
ngrok config add-authtoken "$NGROK_AUTHTOKEN" > /dev/null
ok "ngrok authtoken configured"

# =============================================================================
# STEP 3 — Konnect credentials
# =============================================================================
banner "Step 3 · Kong Konnect Credentials"
info "Personal Access Token: https://cloud.konghq.com → Account → Personal Access Tokens"
info "CP name and Proxy URL: Konnect dashboard → Gateway Manager → your Serverless CP"

ask        KONNECT_TOKEN     "Konnect Personal Access Token" "" secret
ask        KONNECT_CP_NAME   "Control Plane name" "serverless-default"
ask        KONNECT_PROXY_URL "Serverless Proxy URL (https://xxxx.us.serverless.konghq.com)" ""

# =============================================================================
# STEP 4 — Build and start local Docker services
# =============================================================================
banner "Step 4 · Local Services (Docker)"

if [[ "$SKIP_DOCKER" == "true" ]]; then
  warn "Skipping Docker (--skip-docker passed)"
else
  step "Building and starting mcp-server + guardrail-service..."
  docker compose -f docker-compose-serverless.yml up --build -d

  step "Waiting for services to become healthy..."
  for service in mcp-server guardrail-service; do
    elapsed=0
    echo -n "  Waiting for ${service}"
    while (( elapsed < 60 )); do
      health=$(docker inspect --format='{{.State.Health.Status}}' "$service" 2>/dev/null || echo "starting")
      if [[ "$health" == "healthy" ]]; then
        echo " ✓"
        break
      fi
      sleep 3; elapsed=$((elapsed+3)); echo -n "."
    done
    if [[ "$health" != "healthy" ]]; then
      warn "${service} health check timed out — check: docker compose -f docker-compose-serverless.yml logs ${service}"
    fi
  done
fi

# =============================================================================
# STEP 5 — Start ngrok tunnels (single agent, both tunnels)
# =============================================================================
banner "Step 5 · ngrok Tunnels"

# Kill any existing ngrok agent so we start fresh
pkill -x ngrok 2>/dev/null || true
sleep 1

step "Opening Terminal window for ngrok (both tunnels)..."
# ngrok 3.x: --config replaces default config, so pass --authtoken explicitly
# so the new Terminal window doesn't need the default config file.
NGROK_CFG="$(pwd)/ngrok-serverless.yml"
open_terminal_window "ngrok tunnels" \
  "ngrok start --all --config ${NGROK_CFG} --authtoken ${NGROK_AUTHTOKEN}"

ok "ngrok window opened — waiting for tunnels to come up..."
sleep 3

# =============================================================================
# STEP 6 — Detect tunnel URLs and write to .env
# =============================================================================
banner "Step 6 · Detecting Tunnel URLs"
info "Polling ngrok API — waiting for both tunnels to come up..."

MCP_SERVER_NGROK_URL=$(detect_ngrok_url 8092 90) || MCP_SERVER_NGROK_URL=""
if [[ -n "$MCP_SERVER_NGROK_URL" ]]; then
  env_set MCP_SERVER_NGROK_URL "$MCP_SERVER_NGROK_URL"
  ok "MCP Server URL: $MCP_SERVER_NGROK_URL"
else
  warn "Could not auto-detect MCP Server tunnel URL. Update MCP_SERVER_NGROK_URL in .env manually."
fi

GUARDRAIL_URL=$(detect_ngrok_url 8089 90) || GUARDRAIL_URL=""
if [[ -n "$GUARDRAIL_URL" ]]; then
  GUARDRAIL_NGROK_HOST="${GUARDRAIL_URL#https://}"
  env_set GUARDRAIL_NGROK_HOST "$GUARDRAIL_NGROK_HOST"
  ok "Guardrail Service Host: $GUARDRAIL_NGROK_HOST"
else
  warn "Could not auto-detect Guardrail Service tunnel URL. Update GUARDRAIL_NGROK_HOST in .env manually."
fi

# =============================================================================
# STEP 7 — Optional: push to Konnect via deck
# =============================================================================
banner "Step 7 · Push Config to Konnect"

if [[ "$SKIP_DECK" == "true" ]]; then
  warn "Skipping deck push (--skip-deck passed)"
else
  echo -en "  Push Kong config to Konnect now? [y/N]: "
  read -r push_confirm
  if [[ "$push_confirm" =~ ^[Yy]$ ]]; then
    ./deck-push.sh sync
  else
    info "Skipped. Run when ready:"
    echo -e "    ${CYAN}./deck-push.sh${NC}"
  fi
fi

# =============================================================================
# Summary
# =============================================================================
banner "Setup Complete"

# Re-read final .env values
source_env() { set -o allexport; source "$ENV_FILE"; set +o allexport; } 2>/dev/null || true
source_env

echo ""
echo -e "  ${BOLD}Service URLs:${NC}"
echo -e "    MCP Server (local)        ${CYAN}http://localhost:8092${NC}"
echo -e "    Guardrail Service (local) ${CYAN}http://localhost:8089${NC}"
echo ""
echo -e "  ${BOLD}ngrok Tunnel URLs (in .env):${NC}"
echo -e "    MCP       ${CYAN}${MCP_SERVER_NGROK_URL:-not yet set}${NC}"
echo -e "    Guardrail ${CYAN}${GUARDRAIL_NGROK_HOST:-not yet set}${NC}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
  echo -e "    ${CYAN}./deck-push.sh${NC}              push Kong config to Konnect (if not done above)"
  echo -e "    ${CYAN}./test-serverless.sh local${NC}  test local MCP server + OPA policy"
  echo -e "    ${CYAN}./test-serverless.sh${NC}        full E2E test via Konnect Serverless"
