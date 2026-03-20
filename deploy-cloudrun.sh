#!/usr/bin/env bash
# ============================================================================
# NemoKube — Cloud Run Edition
# Deploy NemoClaw + NIM inference as serverless Cloud Run services with L4 GPU.
# Scale-to-zero when idle. No cluster management.
# https://github.com/NVIDIA/NemoClaw → Cloud Run
# ============================================================================
set -euo pipefail

# ── Colors & helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

step() { echo -e "\n${CYAN}━━━ Step $1/$TOTAL_STEPS: $2 ━━━${NC}\n"; }
ok()   { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }

TOTAL_STEPS=8

# ── Base configuration ───────────────────────────────────────────────────────
GCP_PROJECT="${GCP_PROJECT:?Set GCP_PROJECT to your Google Cloud project ID}"
REGION="${REGION:-us-central1}"
AR_REPO="nemokube-images"

# Required — get yours at https://build.nvidia.com
NVIDIA_API_KEY="${NVIDIA_API_KEY:?Set NVIDIA_API_KEY from build.nvidia.com}"

# ── Model selection ──────────────────────────────────────────────────────────
# Cloud Run GPU supports L4 only — so we default to Llama 3.1 8B.
# Larger models (Nemotron 30B/49B/120B) need A100/H100 — use the GKE deploy for those.

declare -A MODEL_ID MODEL_IMAGE MODEL_CPU MODEL_MEM
# 1) Llama 8B — fits L4, recommended for Cloud Run
MODEL_ID[1]="meta/llama-3.1-8b-instruct"
MODEL_IMAGE[1]="nvcr.io/nim/meta/llama-3.1-8b-instruct:latest"
MODEL_CPU[1]="8"
MODEL_MEM[1]="32Gi"
# 2) Llama 8B with lower resources (might work, tighter fit)
MODEL_ID[2]="meta/llama-3.1-8b-instruct"
MODEL_IMAGE[2]="nvcr.io/nim/meta/llama-3.1-8b-instruct:latest"
MODEL_CPU[2]="4"
MODEL_MEM[2]="16Gi"

if [ -z "${NEMOKUBE_MODEL:-}" ]; then
  echo -e "${CYAN}"
  echo "╔═══════════════════════════════════════════════════════════════════╗"
  echo "║               NemoKube Cloud Run — Model Selection               ║"
  echo "╠═══════════════════════════════════════════════════════════════════╣"
  echo "║                                                                   ║"
  echo "║  #  Model                    CPU   Memory   GPU    Est. Cost      ║"
  echo "║  ─  ────────────────────     ───   ──────   ────   ──────────     ║"
  echo "║  1  Llama 3.1 8B (rec.)     8     32 GiB   L4     ~\$1.65/hr     ║"
  echo "║  2  Llama 3.1 8B (minimal)  4     16 GiB   L4     ~\$0.90/hr     ║"
  echo "║                                                                   ║"
  echo "║  Cloud Run only supports L4 GPUs.                                ║"
  echo "║  For A100/H100 models (Nemotron 30B+), use deploy.sh (GKE).     ║"
  echo "║                                                                   ║"
  echo "║  Both services scale to zero — you only pay when in use.         ║"
  echo "║                                                                   ║"
  echo "╚═══════════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  read -p "Select configuration [1-2, default=1]: " model_choice
  NEMOKUBE_MODEL="${model_choice:-1}"
fi

[[ "${NEMOKUBE_MODEL}" =~ ^[1-2]$ ]] || fail "Invalid selection: ${NEMOKUBE_MODEL}. Choose 1-2."

NIM_MODEL="${MODEL_ID[$NEMOKUBE_MODEL]}"
NIM_SOURCE_IMAGE="${MODEL_IMAGE[$NEMOKUBE_MODEL]}"
NIM_CPU="${MODEL_CPU[$NEMOKUBE_MODEL]}"
NIM_MEM="${MODEL_MEM[$NEMOKUBE_MODEL]}"
NIM_MODEL_SHORT="${NIM_MODEL##*/}"    # "llama-3.1-8b-instruct"

# Cloud Run image names (in your Artifact Registry)
NIM_IMAGE="${REGION}-docker.pkg.dev/${GCP_PROJECT}/${AR_REPO}/nim-${NIM_MODEL_SHORT}:latest"
SANDBOX_IMAGE="${REGION}-docker.pkg.dev/${GCP_PROJECT}/${AR_REPO}/nemokube-sandbox:latest"

# Min instances — set to 1 to avoid cold starts (costs ~$0.67/hr idle)
NIM_MIN_INSTANCES="${NIM_MIN_INSTANCES:-0}"
GATEWAY_MIN_INSTANCES="${GATEWAY_MIN_INSTANCES:-0}"

# ── Summary & confirmation ───────────────────────────────────────────────────
echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║          NemoKube Cloud Run — Deployment Summary          ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Project      : ${GCP_PROJECT}"
echo "║  Region       : ${REGION}"
echo "║  Model        : ${NIM_MODEL}"
echo "║  NIM CPU/Mem  : ${NIM_CPU} vCPU / ${NIM_MEM}"
echo "║  GPU          : NVIDIA L4 (24 GB)"
echo "║  Scale-to-zero: NIM min=${NIM_MIN_INSTANCES}, Gateway min=${GATEWAY_MIN_INSTANCES}"
echo "║  Est. cost    : ~\$0/hr when idle, ~\$1.65/hr when active"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

read -p "Proceed with deployment? [y/N] " confirm
[[ "$confirm" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
# Step 1: Enable APIs
# ══════════════════════════════════════════════════════════════════════════════
step 1 "Enabling GCP APIs"
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  compute.googleapis.com \
  --project="${GCP_PROJECT}" --quiet
ok "APIs enabled"

# ══════════════════════════════════════════════════════════════════════════════
# Step 2: Create Artifact Registry
# ══════════════════════════════════════════════════════════════════════════════
step 2 "Setting up Artifact Registry"
gcloud artifacts repositories create "${AR_REPO}" \
  --project="${GCP_PROJECT}" \
  --repository-format=docker \
  --location="${REGION}" \
  --description="NemoKube container images" 2>/dev/null || true
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
ok "Artifact Registry ready: ${REGION}-docker.pkg.dev/${GCP_PROJECT}/${AR_REPO}"

# ══════════════════════════════════════════════════════════════════════════════
# Step 3: Pull & push NIM image
# ══════════════════════════════════════════════════════════════════════════════
step 3 "Mirroring NIM image to Artifact Registry"
echo -e "${DIM}Source: ${NIM_SOURCE_IMAGE}${NC}"
echo -e "${DIM}Target: ${NIM_IMAGE}${NC}"

# Auth to nvcr.io
echo "${NVIDIA_API_KEY}" | docker login nvcr.io -u '$oauthtoken' --password-stdin

# Check if already pushed
if gcloud artifacts docker images describe "${NIM_IMAGE}" --project="${GCP_PROJECT}" &>/dev/null; then
  warn "NIM image already in Artifact Registry — skipping pull/push"
else
  echo "Pulling NIM image (this may take a few minutes)..."
  docker pull "${NIM_SOURCE_IMAGE}"
  docker tag "${NIM_SOURCE_IMAGE}" "${NIM_IMAGE}"
  echo "Pushing to Artifact Registry..."
  docker push "${NIM_IMAGE}"
  ok "NIM image pushed"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 4: Build & push NemoClaw sandbox image
# ══════════════════════════════════════════════════════════════════════════════
step 4 "Building NemoClaw sandbox image"

if gcloud artifacts docker images describe "${SANDBOX_IMAGE}" --project="${GCP_PROJECT}" &>/dev/null; then
  warn "Sandbox image already in Artifact Registry — skipping build"
else
  TMPDIR=$(mktemp -d)
  trap "rm -rf ${TMPDIR}" EXIT
  echo "Cloning NemoClaw..."
  git clone --depth 1 https://github.com/NVIDIA/NemoClaw.git "${TMPDIR}/NemoClaw"
  cd "${TMPDIR}/NemoClaw"

  echo "Building Docker image..."
  docker build -t "nemokube-sandbox:latest" .
  docker tag "nemokube-sandbox:latest" "${SANDBOX_IMAGE}"

  echo "Pushing to Artifact Registry..."
  docker push "${SANDBOX_IMAGE}"
  ok "Sandbox image pushed: ${SANDBOX_IMAGE}"
  cd -
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 5: Deploy NIM inference (GPU service)
# ══════════════════════════════════════════════════════════════════════════════
step 5 "Deploying NIM inference service (GPU)"

echo -e "${DIM}This is the GPU service. Cloud Run will provision an L4 automatically.${NC}"
echo -e "${DIM}First deploy may take 2-5 minutes as the image layers are cached.${NC}"

gcloud run deploy nim-inference \
  --project="${GCP_PROJECT}" \
  --region="${REGION}" \
  --image="${NIM_IMAGE}" \
  --gpu=1 --gpu-type=nvidia-l4 \
  --cpu="${NIM_CPU}" --memory="${NIM_MEM}" \
  --no-allow-unauthenticated \
  --no-cpu-throttling \
  --port=8000 \
  --set-env-vars="NGC_API_KEY=${NVIDIA_API_KEY}" \
  --set-env-vars="NVIDIA_API_KEY=${NVIDIA_API_KEY}" \
  --set-env-vars="NIM_SERVED_MODEL_NAME=${NIM_MODEL_SHORT}" \
  --set-env-vars="NIM_MAX_MODEL_LEN=32768" \
  --set-env-vars="NIM_GPU_MEMORY_UTILIZATION=0.90" \
  --set-env-vars="NIM_TENSOR_PARALLEL_SIZE=1" \
  --min-instances="${NIM_MIN_INSTANCES}" \
  --max-instances=1 \
  --timeout=600 \
  --execution-environment=gen2 \
  --quiet

NIM_URL=$(gcloud run services describe nim-inference \
  --project="${GCP_PROJECT}" --region="${REGION}" \
  --format='value(status.url)')

ok "NIM deployed: ${NIM_URL}"

# ══════════════════════════════════════════════════════════════════════════════
# Step 6: Grant IAM permissions
# ══════════════════════════════════════════════════════════════════════════════
step 6 "Configuring IAM permissions"

# Get the project number for the default compute SA
PROJECT_NUMBER=$(gcloud projects describe "${GCP_PROJECT}" --format='value(projectNumber)')
DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo -e "${DIM}Granting Cloud Run Invoker on nim-inference to: ${DEFAULT_SA}${NC}"
gcloud run services add-iam-policy-binding nim-inference \
  --project="${GCP_PROJECT}" \
  --region="${REGION}" \
  --member="serviceAccount:${DEFAULT_SA}" \
  --role="roles/run.invoker" \
  --quiet 2>/dev/null

ok "IAM configured — gateway can invoke NIM"

# ══════════════════════════════════════════════════════════════════════════════
# Step 7: Deploy NemoClaw gateway (CPU service)
# ══════════════════════════════════════════════════════════════════════════════
step 7 "Deploying NemoClaw gateway (CPU)"

# NemoClaw's nemoclaw-start script has issues (backgrounds gateway, overwrites config).
# We work around this by:
# 1. Let nemoclaw-start run for initial setup (plugins, auth)
# 2. Patch the config with our model and NIM endpoint
# 3. Stop the backgrounded gateway
# 4. Restart gateway in foreground (exec)

STARTUP_SCRIPT='
set -e
echo "[nemokube-cloudrun] Starting NemoClaw setup..."

# Run nemoclaw-start for its setup side effects (plugins, auth tokens)
/usr/local/bin/nemoclaw-start &
SETUP_PID=$!
wait $SETUP_PID 2>/dev/null || true
sleep 2

echo "[nemokube-cloudrun] Patching config for Cloud Run..."
python3 -c "
import json, os

path = os.path.expanduser(\"~/.openclaw/openclaw.json\")
cfg = json.load(open(path))

model = os.environ.get(\"INFERENCE_MODEL\", \"meta/llama-3.1-8b-instruct\")
nim_endpoint = os.environ.get(\"NIM_ENDPOINT\", \"\")
api_key = os.environ.get(\"NVIDIA_API_KEY\", \"\")
chat_url = os.environ.get(\"CHAT_UI_URL\", \"*\")

# Fix the model (nemoclaw-start hardcodes nemotron-3-super-120b)
cfg[\"agents\"][\"defaults\"][\"model\"][\"primary\"] = model

# Set up NIM provider
nim = cfg.setdefault(\"models\", {}).setdefault(\"providers\", {}).setdefault(\"nim-local\", {})
nim[\"baseUrl\"] = nim_endpoint
nim[\"apiKey\"] = api_key
nim[\"api\"] = \"openai-completions\"
short = model.split(\"/\")[-1]
nim[\"models\"] = [{
    \"id\": short,
    \"name\": model,
    \"reasoning\": False,
    \"input\": [\"text\"],
    \"cost\": {\"input\": 0, \"output\": 0, \"cacheRead\": 0, \"cacheWrite\": 0},
    \"contextWindow\": 131072,
    \"maxTokens\": 8192
}]

# Fix allowed origins for Cloud Run URL
gateway = cfg.setdefault(\"gateway\", {})
ctrl = gateway.setdefault(\"controlUi\", {})
ctrl[\"allowedOrigins\"] = [chat_url]
ctrl[\"allowInsecureAuth\"] = True

json.dump(cfg, open(path, \"w\"), indent=2)
print(f\"[nemokube-cloudrun] Config patched: model={model}, endpoint={nim_endpoint}\")
"

# Stop backgrounded gateway, restart in foreground
openclaw gateway stop 2>/dev/null || true
sleep 1
echo "[nemokube-cloudrun] Starting gateway in foreground..."
exec openclaw gateway run
'

gcloud run deploy nemokube-gateway \
  --project="${GCP_PROJECT}" \
  --region="${REGION}" \
  --image="${SANDBOX_IMAGE}" \
  --cpu=2 --memory=4Gi \
  --allow-unauthenticated \
  --port=18789 \
  --set-env-vars="NVIDIA_API_KEY=${NVIDIA_API_KEY}" \
  --set-env-vars="INFERENCE_MODEL=${NIM_MODEL}" \
  --set-env-vars="NIM_ENDPOINT=${NIM_URL}/v1" \
  --set-env-vars="CHAT_UI_URL=PLACEHOLDER" \
  --min-instances="${GATEWAY_MIN_INSTANCES}" \
  --max-instances=2 \
  --timeout=300 \
  --execution-environment=gen2 \
  --command="/bin/bash" \
  --args="-c,${STARTUP_SCRIPT}" \
  --quiet

GATEWAY_URL=$(gcloud run services describe nemokube-gateway \
  --project="${GCP_PROJECT}" --region="${REGION}" \
  --format='value(status.url)')

ok "Gateway deployed: ${GATEWAY_URL}"

# ══════════════════════════════════════════════════════════════════════════════
# Step 8: Update CHAT_UI_URL and finalize
# ══════════════════════════════════════════════════════════════════════════════
step 8 "Finalizing — setting gateway URL for origin checking"

# Now that we know the actual URL, update it
gcloud run services update nemokube-gateway \
  --project="${GCP_PROJECT}" \
  --region="${REGION}" \
  --update-env-vars="CHAT_UI_URL=${GATEWAY_URL}" \
  --quiet

ok "Gateway URL set: ${GATEWAY_URL}"

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║              Cloud Run Deployment Complete!               ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║                                                           ║"
echo "║  NIM Inference : ${NIM_URL}"
echo "║  Gateway       : ${GATEWAY_URL}"
echo "║                                                           ║"
echo "║  Next steps:                                              ║"
echo "║                                                           ║"
echo "║  1. Open the gateway URL in your browser:                 ║"
echo "║     ${GATEWAY_URL}"
echo "║                                                           ║"
echo "║  2. Get the auth token:                                   ║"
echo "║     gcloud run services logs read nemokube-gateway \\     ║"
echo "║       --project=${GCP_PROJECT} \\                          ║"
echo "║       --region=${REGION} --limit=100 | grep token         ║"
echo "║                                                           ║"
echo "║  3. Append token to URL:                                  ║"
echo "║     ${GATEWAY_URL}/#token=YOUR_TOKEN                      ║"
echo "║                                                           ║"
echo "║  Cost: ~\$0/hr idle (scale-to-zero) | ~\$1.65/hr active  ║"
echo "║  First request may take 30-120s (cold start + model load) ║"
echo "║                                                           ║"
echo "║  Cleanup:                                                 ║"
echo "║    gcloud run services delete nim-inference \\             ║"
echo "║      --project=${GCP_PROJECT} --region=${REGION} -q       ║"
echo "║    gcloud run services delete nemokube-gateway \\          ║"
echo "║      --project=${GCP_PROJECT} --region=${REGION} -q       ║"
echo "║    gcloud artifacts repositories delete ${AR_REPO} \\     ║"
echo "║      --location=${REGION} --project=${GCP_PROJECT} -q     ║"
echo "║                                                           ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
