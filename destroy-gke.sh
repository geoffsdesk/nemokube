#!/usr/bin/env bash
# ============================================================================
# NemoKube — Destroy GKE Deployment
# Removes the GKE cluster, Artifact Registry, and any lingering disks.
# ============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

GCP_PROJECT="${GCP_PROJECT:?Set GCP_PROJECT}"
GKE_REGION="${GKE_REGION:-us-central1}"
GKE_CLUSTER="${GKE_CLUSTER:-nemokube-cluster}"
AR_REPO="nemokube-images"

echo -e "${YELLOW}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║            NemoKube GKE — Destroy Resources               ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Project : ${GCP_PROJECT}"
echo "║  Region  : ${GKE_REGION}"
echo "║  Cluster : ${GKE_CLUSTER}"
echo "║                                                           ║"
echo "║  This will delete:                                        ║"
echo "║    • GKE cluster (all nodes, GPU included)                ║"
echo "║    • Artifact Registry: ${AR_REPO}                        ║"
echo "║    • Any lingering nemokube PVC disks                     ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

read -p "Are you sure? [y/N] " confirm
[[ "$confirm" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

echo ""
echo -e "${CYAN}Deleting GKE cluster '${GKE_CLUSTER}'...${NC}"
echo -e "${YELLOW}(This takes 3-5 minutes)${NC}"

gcloud container clusters delete "${GKE_CLUSTER}" \
  --region="${GKE_REGION}" --project="${GCP_PROJECT}" --quiet 2>/dev/null \
  && echo -e "${GREEN}✓ Cluster deleted${NC}" \
  || echo -e "${YELLOW}⚠ Cluster not found (already deleted?)${NC}"

echo ""
echo -e "${CYAN}Deleting Artifact Registry...${NC}"

gcloud artifacts repositories delete "${AR_REPO}" \
  --location="${GKE_REGION}" --project="${GCP_PROJECT}" --quiet 2>/dev/null \
  && echo -e "${GREEN}✓ Artifact Registry deleted${NC}" \
  || echo -e "${YELLOW}⚠ Artifact Registry not found (already deleted?)${NC}"

echo ""
echo -e "${CYAN}Checking for lingering disks...${NC}"

DISKS=$(gcloud compute disks list --project="${GCP_PROJECT}" \
  --filter="name~nemokube" --format="csv[no-heading](name,zone)" 2>/dev/null)

if [ -n "${DISKS}" ]; then
  echo "Found lingering disks:"
  echo "${DISKS}" | while IFS=, read -r name zone; do
    echo -e "  Deleting ${name} in ${zone}..."
    gcloud compute disks delete "${name}" --zone="${zone}" \
      --project="${GCP_PROJECT}" --quiet 2>/dev/null || true
  done
  echo -e "${GREEN}✓ Disks cleaned up${NC}"
else
  echo -e "${GREEN}✓ No lingering disks found${NC}"
fi

echo ""
echo -e "${GREEN}Done. All GKE resources cleaned up.${NC}"
