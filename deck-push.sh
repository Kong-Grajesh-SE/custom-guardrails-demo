#!/usr/bin/env bash
# =============================================================================
# deck-push.sh — Sync kong-serverless.yaml to Konnect Serverless
#
# Usage:
#   ./deck-push.sh           # sync (plan + apply)
#   ./deck-push.sh diff      # dry-run: show what would change
#   ./deck-push.sh ping      # verify Konnect credentials only
# =============================================================================
set -euo pipefail

# ── Load .env ─────────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Copy .env.example → .env and fill in values."
  exit 1
fi
# shellcheck disable=SC1091
set -o allexport
source .env
set +o allexport

# ── Validate required vars ────────────────────────────────────────────────────
required_vars=(KONNECT_TOKEN KONNECT_CP_NAME MCP_SERVER_NGROK_URL GUARDRAIL_NGROK_HOST)
missing=()
for v in "${required_vars[@]}"; do
  [[ -z "${!v:-}" ]] && missing+=("$v")
done
if (( ${#missing[@]} > 0 )); then
  echo "ERROR: Missing required .env variables:"
  printf '  %s\n' "${missing[@]}"
  exit 1
fi

# ── Check deck is installed ───────────────────────────────────────────────────
if ! command -v deck &>/dev/null; then
  echo "deck not found. Install with:"
  echo "  brew install kong/kong/deck        (macOS)"
  echo "  or: https://docs.konghq.com/deck/latest/installation/"
  exit 1
fi

# ── Check envsubst is installed ──────────────────────────────────────────────
if ! command -v envsubst &>/dev/null; then
  echo "envsubst not found. Install with:"
  echo "  brew install gettext && brew link --force gettext   (macOS)"
  exit 1
fi

MODE="${1:-sync}"

# ── Substitute env vars into the deck YAML ────────────────────────────────────
TMP_YAML=$(mktemp /tmp/kong-serverless-resolved.XXXX.yaml)
trap 'rm -f "$TMP_YAML"' EXIT
envsubst < kong-serverless.yaml > "$TMP_YAML"

echo ""
echo "Konnect Control Plane : $KONNECT_CP_NAME"
echo "MCP Server URL        : $MCP_SERVER_NGROK_URL"
echo "Guardrail Host        : $GUARDRAIL_NGROK_HOST"
echo ""

case "$MODE" in
  ping)
    deck gateway ping \
      --konnect-token "$KONNECT_TOKEN" \
      --konnect-control-plane-name "$KONNECT_CP_NAME"
    ;;
  diff)
    deck gateway diff "$TMP_YAML" \
      --konnect-token "$KONNECT_TOKEN" \
      --konnect-control-plane-name "$KONNECT_CP_NAME" \
      --select-tag mcp-demo
    ;;
  sync)
    deck gateway diff "$TMP_YAML" \
      --konnect-token "$KONNECT_TOKEN" \
      --konnect-control-plane-name "$KONNECT_CP_NAME" \
      --select-tag mcp-demo
    echo ""
    read -rp "Apply changes to Konnect? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    deck gateway sync "$TMP_YAML" \
      --konnect-token "$KONNECT_TOKEN" \
      --konnect-control-plane-name "$KONNECT_CP_NAME" \
      --select-tag mcp-demo
    echo ""
    echo "Done. Test with:"
    echo "  ./test-serverless.sh"
    ;;
  *)
    echo "Usage: $0 [sync|diff|ping]"
    exit 1
    ;;
esac
