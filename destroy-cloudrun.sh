#!/usr/bin/env bash
# ============================================================================
# NemoKube — Destroy Cloud Run Deployment
# Removes both Cloud Run services and the Artifact Registry repo.
# ============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

GCP_PROJECT="${GCP_PROJECT:?Set GCP_PROJECT}"
REGION="${REGION:-us-central1}"
AR_REPO="nemokube-images"

echo -e "${YELLOW}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║         NemoKube Cloud Run — Destroy Resources            ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Project : ${GCP_PROJECT}"
echo "║  Region  : ${REGION}"
echo "║                                                           ║"
echo "║  This will delete:                                        ║"
echo "║    • Cloud Run service: nim-inference                     ║"
echo "║    • Cloud Run service: nemokube-gateway                  ║"
echo "║    • Artifact Registry: ${AR_REPO}                        ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

read -p "Are you sure? [y/N] " confirm
[[ "$confirm" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

echo ""
echo -e "${CYAN}Deleting Cloud Run services...${NC}"

gcloud run services delete nim-inference \
  --project="${GCP_PROJECT}" --region="${REGION}" --quiet 2>/dev/null \
  && echo -e "${GREEN}✓ nim-inference deleted${NC}" \
  || echo -e "${YELLOW}⚠ nim-inference not found (already deleted?)${NC}"

gcloud run services delete nemokube-gateway \
  --project="${GCP_PROJECT}" --region="${REGION}" --quiet 2>/dev/null \
  && echo -e "${GREEN}✓ nemokube-gateway deleted${NC}" \
  || echo -e "${YELLOW}⚠ nemokube-gateway not found (already deleted?)${NC}"

echo ""
echo -e "${CYAN}Deleting Artifact Registry...${NC}"

gcloud artifacts repositories delete "${AR_REPO}" \
  --location="${REGION}" --project="${GCP_PROJECT}" --quiet 2>/dev/null \
  && echo -e "${GREEN}✓ Artifact Registry deleted${NC}" \
  || echo -e "${YELLOW}⚠ Artifact Registry not found (already deleted?)${NC}"

echo ""
echo -e "${GREEN}Done. All Cloud Run resources cleaned up. Billing stops immediately.${NC}"
