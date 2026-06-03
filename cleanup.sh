#!/usr/bin/env bash
# =============================================================================
# Custom Guardrails Demo — Interactive Cleanup Script
#
# Stops all services and optionally removes generated files and Docker images.
#
# Usage:
#   chmod +x cleanup.sh
#   ./cleanup.sh
# =============================================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}  ▶${NC}  $1"; }
success() { echo -e "${GREEN}  ✓${NC}  $1"; }
warn()    { echo -e "${YELLOW}  ⚠${NC}  $1"; }
error()   { echo -e "${RED}  ✗${NC}  $1"; }
header()  {
  echo ""
  echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  $1${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
  echo ""
}

confirm() {
  local prompt_text="$1"
  local default="${2:-y}"
  local input
  if [[ "$default" == "y" ]]; then
    echo -en "  ${BOLD}${prompt_text}${NC} (Y/n): "
  else
    echo -en "  ${BOLD}${prompt_text}${NC} (y/N): "
  fi
  read -r input
  input="${input:-$default}"
  [[ "$input" =~ ^[Yy]$ ]]
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

header "Custom Guardrails Demo — Cleanup"

echo -e "  This script will help you tear down the demo environment."
echo -e "  You'll be prompted before each action."
echo ""

# ── Step 1: Stop Docker Containers ──────────────────────────────────────────
header "Step 1: Stop Docker Containers"

CONTAINERS_RUNNING=false
if docker compose ps --status running 2>/dev/null | grep -q "guardrail"; then
  CONTAINERS_RUNNING=true
fi

if $CONTAINERS_RUNNING; then
  info "Running containers detected:"
  docker compose ps 2>/dev/null || true
  echo ""

  if confirm "Stop all running containers?"; then
    docker compose down
    success "All containers stopped and removed"
  else
    warn "Skipped — containers still running"
  fi
else
  success "No running containers found"
fi

# ── Step 2: Remove Generated Kong Config ─────────────────────────────────────
header "Step 2: Clean Up Generated Files"

CLEANED_FILES=0

if [[ -f "$SCRIPT_DIR/kong-generated.yaml" ]]; then
  echo -e "  Found: ${CYAN}kong-generated.yaml${NC}"
  echo -e "  ${YELLOW}This file contains your Mistral API key!${NC}"
  if confirm "Remove kong-generated.yaml?"; then
    rm -f "$SCRIPT_DIR/kong-generated.yaml"
    success "Removed kong-generated.yaml"
    CLEANED_FILES=$((CLEANED_FILES + 1))
  else
    warn "Skipped — kong-generated.yaml preserved"
  fi
else
  info "No kong-generated.yaml found"
fi

echo ""

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  echo -e "  Found: ${CYAN}.env${NC} (configuration with API keys)"
  echo -e "  ${YELLOW}This file contains your Mistral API key and Konnect token!${NC}"
  if confirm "Remove .env file?" "n"; then
    rm -f "$SCRIPT_DIR/.env"
    success "Removed .env"
    CLEANED_FILES=$((CLEANED_FILES + 1))
  else
    warn "Skipped — .env preserved"
  fi
else
  info "No .env found"
fi

# ── Step 3: Remove Docker Images ─────────────────────────────────────────────
header "Step 3: Docker Images"

IMAGE_NAME=$(docker compose config --images 2>/dev/null | head -1 || echo "")
if [[ -n "$IMAGE_NAME" ]] && docker image inspect "$IMAGE_NAME" &>/dev/null 2>&1; then
  echo -e "  Found Docker image: ${CYAN}${IMAGE_NAME}${NC}"
  if confirm "Remove the guardrail-service Docker image?" "n"; then
    docker rmi "$IMAGE_NAME" 2>/dev/null || true
    success "Removed Docker image: $IMAGE_NAME"
  else
    warn "Skipped — Docker image preserved (faster rebuilds next time)"
  fi
else
  info "No guardrail-service Docker image found"
fi

# ── Step 4: Prune Docker Resources ───────────────────────────────────────────
header "Step 4: Docker Cleanup (Optional)"

echo -e "  This removes unused Docker resources (dangling images, build cache, etc.)"
if confirm "Run docker system prune?" "n"; then
  docker system prune -f
  success "Docker system pruned"
else
  warn "Skipped — Docker resources preserved"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
header "Cleanup Complete!"

echo -e "  ${GREEN}${BOLD}Actions taken:${NC}"
if ! $CONTAINERS_RUNNING; then
  echo -e "    • No containers were running"
else
  echo -e "    • Containers stopped"
fi
echo -e "    • ${CLEANED_FILES} generated file(s) removed"
echo ""
echo -e "  ${YELLOW}Remember:${NC} If you loaded kong-generated.yaml into your hosted"
echo -e "  Kong gateway, you may want to remove/update that config as well."
echo ""
echo -e "  To start fresh:  ${CYAN}./startup.sh${NC}"
echo ""
