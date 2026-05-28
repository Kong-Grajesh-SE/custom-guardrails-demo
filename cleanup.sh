#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — Kong Konnect Serverless MCP + OPA demo
#
# Tears down everything that setup.sh created:
#   1. Kill ngrok tunnels
#   2. Stop and remove Docker containers (mcp-server, guardrail-service)
#   3. Remove Docker images built for this project
#   4. Remove Docker networks and volumes created by compose
#   5. Optionally delete the .env file
#
# Usage:
#   ./cleanup.sh            # interactive
#   ./cleanup.sh --yes      # non-interactive: skip all prompts (keep .env)
#   ./cleanup.sh --purge    # also delete .env (implies --yes)
# =============================================================================
set -euo pipefail

# ── Parse flags ───────────────────────────────────────────────────────────────
YES=false
PURGE=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y)  YES=true ;;
    --purge)   PURGE=true; YES=true ;;
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

COMPOSE_FILE="docker-compose-serverless.yml"
ENV_FILE=".env"

banner "Cleanup · Kong Konnect Serverless Demo"

# =============================================================================
# STEP 1 — Kill ngrok
# =============================================================================
banner "Step 1 · Stopping ngrok"

if pgrep -x ngrok &>/dev/null; then
  step "Killing ngrok processes..."
  pkill -x ngrok 2>/dev/null || true
  sleep 1
  if pgrep -x ngrok &>/dev/null; then
    warn "ngrok still running — try: pkill -9 -x ngrok"
  else
    ok "ngrok stopped"
  fi
else
  ok "ngrok is not running"
fi

# =============================================================================
# STEP 2 — Stop Docker containers
# =============================================================================
banner "Step 2 · Stopping Docker containers"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  warn "Compose file '$COMPOSE_FILE' not found — skipping Docker teardown"
else
  step "Running docker compose down..."
  docker compose -f "$COMPOSE_FILE" down --remove-orphans
  ok "Containers stopped and removed"
fi

# =============================================================================
# STEP 3 — Remove Docker images
# =============================================================================
banner "Step 3 · Removing Docker images"

# Images built by this project (compose names them as <dir>-<service>)
PROJ_DIR=$(basename "$(pwd)")
IMAGES=(
  "${PROJ_DIR}-mcp-server"
  "${PROJ_DIR}-guardrail-service"
  "mcp-server"
  "guardrail-service"
)

for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" &>/dev/null; then
    step "Removing image: $img"
    docker rmi "$img" --force 2>/dev/null && ok "Removed $img" || warn "Could not remove $img"
  fi
done

# Remove dangling (untagged) images left over from builds
DANGLING=$(docker images -f "dangling=true" -q)
if [[ -n "$DANGLING" ]]; then
  step "Removing dangling images..."
  # shellcheck disable=SC2086
  docker rmi $DANGLING --force 2>/dev/null && ok "Dangling images removed" || warn "Some dangling images could not be removed"
fi

# =============================================================================
# STEP 4 — Remove Docker volumes and networks
# =============================================================================
banner "Step 4 · Removing Docker volumes and networks"

# Volumes created by compose
step "Pruning unused volumes created by this project..."
docker volume ls --filter "label=com.docker.compose.project=${PROJ_DIR}" -q | \
  xargs -r docker volume rm 2>/dev/null && ok "Volumes removed" || true

# Remove the compose-created network (usually <proj>_default)
NETWORK="${PROJ_DIR}_default"
if docker network inspect "$NETWORK" &>/dev/null; then
  step "Removing network: $NETWORK"
  docker network rm "$NETWORK" 2>/dev/null && ok "Network removed" || warn "Network in use, skipping"
fi

# =============================================================================
# STEP 5 — Optionally remove .env
# =============================================================================
banner "Step 5 · Environment file"

if [[ -f "$ENV_FILE" ]]; then
  if [[ "$PURGE" == "true" ]]; then
    rm -f "$ENV_FILE"
    ok ".env deleted (--purge)"
  elif [[ "$YES" == "true" ]]; then
    warn ".env kept (use --purge to delete it)"
  else
    echo -en "  Delete ${CYAN}.env${NC} (contains tokens/credentials)? [y/N]: "
    read -r del_env
    if [[ "$del_env" =~ ^[Yy]$ ]]; then
      rm -f "$ENV_FILE"
      ok ".env deleted"
    else
      warn ".env kept"
    fi
  fi
else
  ok ".env not present — nothing to delete"
fi

# =============================================================================
# Summary
# =============================================================================
banner "Cleanup Complete"

echo ""
echo -e "  ${BOLD}What was cleaned:${NC}"
echo -e "    ${GREEN}✓${NC} ngrok processes terminated"
echo -e "    ${GREEN}✓${NC} Docker containers stopped and removed"
echo -e "    ${GREEN}✓${NC} Docker images removed"
echo -e "    ${GREEN}✓${NC} Docker volumes and networks pruned"
echo ""
echo -e "  ${BOLD}To set up again:${NC}"
echo -e "    ${CYAN}./setup.sh${NC}"
echo ""
