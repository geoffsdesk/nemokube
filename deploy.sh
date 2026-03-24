#!/usr/bin/env bash
# ============================================================================
# NemoKube v2 — Capacity-Aware Deployment of NemoClaw on GKE
# Uses regional clusters + ComputeClass + NAP for automatic GPU zone selection.
# https://github.com/NVIDIA/NemoClaw → Kubernetes
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

TOTAL_STEPS=14

# ── Base configuration ────────────────────────────────────────────────────────
GCP_PROJECT="${GCP_PROJECT:?Set GCP_PROJECT to your Google Cloud project ID}"
GKE_REGION="${GKE_REGION:-us-central1}"
GKE_CLUSTER="${GKE_CLUSTER:-nemokube-cluster}"
AR_REPO="nemokube-images"
SANDBOX_IMAGE="nemokube-sandbox"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${GKE_REGION}-docker.pkg.dev/${GCP_PROJECT}/${AR_REPO}/${SANDBOX_IMAGE}:${IMAGE_TAG}"

# Required — get yours at https://build.nvidia.com
NVIDIA_API_KEY="${NVIDIA_API_KEY:?Set NVIDIA_API_KEY from build.nvidia.com}"

# ── Model & GPU sizing ───────────────────────────────────────────────────────
# Override any of these with env vars to skip the interactive menu.
#   NEMOKUBE_MODEL=2  NEMOKUBE_SPOT=yes  GPU_MACHINE_TYPE=g2-standard-24  ./deploy.sh
#
# Model table (verified runtime VRAM — not checkpoint size):
#   Model                                  Runtime VRAM   Recommended GPU
#   ─────────────────────────────────────  ─────────────  ────────────────
#   nvidia/nemotron-3-nano                  ~23 GB        A100-40GB (does NOT fit L4)
#   nvidia/llama-3.3-nemotron-super-49b-v1  ~24 GB        A100-40GB
#   nvidia/nemotron-3-super-120b-a12b       ~40 GB        A100-40GB
#   meta/llama-3.1-8b-instruct             ~16 GB        L4 (24GB)

declare -A MODEL_ID MODEL_IMAGE MODEL_VRAM MODEL_GPU MODEL_MACHINE MODEL_PVC MODEL_MEM MODEL_COST MODEL_ACCEL
# 1) Nano 30B — best balance of quality and cost
MODEL_ID[1]="nvidia/nemotron-3-nano"
MODEL_IMAGE[1]="nvcr.io/nim/nvidia/nemotron-3-nano:latest"
MODEL_VRAM[1]="24GB"
MODEL_GPU[1]="nvidia-tesla-a100"
MODEL_MACHINE[1]="a2-highgpu-1g"
MODEL_ACCEL[1]="nvidia-tesla-a100"
MODEL_PVC[1]="80Gi"
MODEL_MEM[1]="24Gi"
MODEL_COST[1]="~\$3.67/hr (A100 on-demand) · ~\$1.10/hr (Spot)"
# 2) Super 49B — higher quality, still single A100
MODEL_ID[2]="nvidia/llama-3.3-nemotron-super-49b-v1"
MODEL_IMAGE[2]="nvcr.io/nim/nvidia/llama-3.3-nemotron-super-49b-v1:latest"
MODEL_VRAM[2]="24GB"
MODEL_GPU[2]="nvidia-tesla-a100"
MODEL_MACHINE[2]="a2-highgpu-1g"
MODEL_ACCEL[2]="nvidia-tesla-a100"
MODEL_PVC[2]="120Gi"
MODEL_MEM[2]="24Gi"
MODEL_COST[2]="~\$3.67/hr (A100 on-demand) · ~\$1.10/hr (Spot)"
# 3) Super 120B — full power, needs A100
MODEL_ID[3]="nvidia/nemotron-3-super-120b-a12b"
MODEL_IMAGE[3]="nvcr.io/nim/nvidia/nemotron-3-super-120b-a12b:latest"
MODEL_VRAM[3]="40GB"
MODEL_GPU[3]="nvidia-tesla-a100"
MODEL_MACHINE[3]="a2-highgpu-1g"
MODEL_ACCEL[3]="nvidia-tesla-a100"
MODEL_PVC[3]="250Gi"
MODEL_MEM[3]="40Gi"
MODEL_COST[3]="~\$3.67/hr (A100 on-demand) · ~\$1.10/hr (Spot)"
# 4) Llama 8B — lightweight testing, fits on L4
MODEL_ID[4]="meta/llama-3.1-8b-instruct"
MODEL_IMAGE[4]="nvcr.io/nim/meta/llama-3.1-8b-instruct:latest"
MODEL_VRAM[4]="16GB"
MODEL_GPU[4]="nvidia-l4"
MODEL_MACHINE[4]="g2-standard-8"
MODEL_ACCEL[4]="nvidia-l4"
MODEL_PVC[4]="40Gi"
MODEL_MEM[4]="16Gi"
MODEL_COST[4]="~\$0.70/hr (L4 on-demand) · ~\$0.21/hr (Spot)"

# ── Interactive model selection (skip with NEMOKUBE_MODEL env var) ────────────
if [ -z "${NEMOKUBE_MODEL:-}" ]; then
  echo -e "${CYAN}"
  echo "╔═══════════════════════════════════════════════════════════════════╗"
  echo "║                    NemoKube — Model Selection                     ║"
  echo "╠═══════════════════════════════════════════════════════════════════╣"
  echo "║                                                                   ║"
  echo "║  #  Model                        VRAM    GPU          Est. Cost   ║"
  echo "║  ─  ─────────────────────────    ─────   ──────────   ──────────  ║"
  echo "║  1  Nemotron Nano 30B (rec.)     24GB    A100 (40GB)  \$3.67/hr   ║"
  echo "║  2  Nemotron Super 49B           24GB    A100 (40GB)  \$3.67/hr   ║"
  echo "║  3  Nemotron Super 120B          40GB    A100 (40GB)  \$3.67/hr   ║"
  echo "║  4  Llama 3.1 8B (lightweight)   16GB    L4 (24GB)    \$0.70/hr   ║"
  echo "║                                                                   ║"
  echo "║  Costs shown are on-demand. Spot VMs are 60-70% cheaper.         ║"
  echo "║                                                                   ║"
  echo "╚═══════════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  read -p "Select model [1-4, default=1]: " model_choice
  NEMOKUBE_MODEL="${model_choice:-1}"
fi

# Validate selection
if [[ ! "${NEMOKUBE_MODEL}" =~ ^[1-4]$ ]]; then
  fail "Invalid model selection: ${NEMOKUBE_MODEL}. Choose 1-4."
fi

NIM_MODEL="${MODEL_ID[$NEMOKUBE_MODEL]}"
NIM_IMAGE="${MODEL_IMAGE[$NEMOKUBE_MODEL]}"
NIM_VRAM="${MODEL_VRAM[$NEMOKUBE_MODEL]}"
NIM_PVC_SIZE="${MODEL_PVC[$NEMOKUBE_MODEL]}"
NIM_MEM="${MODEL_MEM[$NEMOKUBE_MODEL]}"

# GPU machine type — user can override with GPU_MACHINE_TYPE env var
GPU_MACHINE_TYPE="${GPU_MACHINE_TYPE:-${MODEL_MACHINE[$NEMOKUBE_MODEL]}}"
GPU_TYPE="${MODEL_GPU[$NEMOKUBE_MODEL]}"
GPU_ACCEL="${MODEL_ACCEL[$NEMOKUBE_MODEL]}"

# Derive the GKE accelerator label
case "${GPU_TYPE}" in
  nvidia-l4)           GPU_LABEL="nvidia-l4" ;;
  nvidia-tesla-a100)   GPU_LABEL="nvidia-tesla-a100" ;;
  nvidia-h100-80gb)    GPU_LABEL="nvidia-h100" ;;
  *)                   GPU_LABEL="${GPU_TYPE}" ;;
esac

# ── Spot VM selection (skip with NEMOKUBE_SPOT env var) ───────────────────────
# Spot VMs are 60-70% cheaper but can be preempted. Viable for NemoKube because:
#   - Model weights are cached on a PVC (survives preemption)
#   - NIM restarts from cache in ~2-3 min (vs ~8 min cold)
#   - NemoClaw is alpha / dev-test — brief downtime is acceptable
# NOT recommended for production inference serving without a fallback.
if [ -z "${NEMOKUBE_SPOT:-}" ]; then
  echo ""
  echo -e "${BOLD}Use Spot VMs for the GPU node pool?${NC}"
  echo -e "  ${GREEN}yes${NC} — 60-70% cheaper, but nodes can be preempted (model reloads in ~2 min from cache)"
  echo -e "  ${CYAN}no${NC}  — on-demand pricing, guaranteed availability"
  echo ""
  read -p "Use Spot VMs? [y/N]: " spot_choice
  if [[ "${spot_choice}" =~ ^[Yy] ]]; then
    NEMOKUBE_SPOT="yes"
  else
    NEMOKUBE_SPOT="no"
  fi
fi

SPOT_FLAGS=""
if [[ "${NEMOKUBE_SPOT}" == "yes" ]]; then
  SPOT_FLAGS="--spot"
  SPOT_LABEL="Spot (preemptible)"
else
  SPOT_LABEL="On-demand"
fi

# ── Summary & confirmation ────────────────────────────────────────────────────
echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║              NemoKube — Deployment Summary                ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Project  : ${GCP_PROJECT}"
echo "║  Region   : ${GKE_REGION} (regional cluster — auto zone selection)"
echo "║  Cluster  : ${GKE_CLUSTER}"
echo "║  Model    : ${NIM_MODEL}"
echo "║  VRAM     : ${NIM_VRAM} required"
echo "║  GPU      : ${GPU_ACCEL} (${GPU_MACHINE_TYPE})"
echo "║  Pricing  : ${SPOT_LABEL}"
echo "║  Est. cost: ${MODEL_COST[$NEMOKUBE_MODEL]}"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
if [ "${GPU_MACHINE_TYPE}" != "${MODEL_MACHINE[$NEMOKUBE_MODEL]}" ]; then
  warn "Custom machine type override: ${GPU_MACHINE_TYPE} (default was ${MODEL_MACHINE[$NEMOKUBE_MODEL]})"
fi

read -p "Proceed with deployment? [y/N] " confirm
[[ "$confirm" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
# Step 1: Enable APIs
# ══════════════════════════════════════════════════════════════════════════════
step 1 "Enabling GCP APIs"
gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  compute.googleapis.com \
  --project="${GCP_PROJECT}" --quiet
ok "APIs enabled"

# ══════════════════════════════════════════════════════════════════════════════
# Step 2: GPU Capacity Pre-Flight Check
# ══════════════════════════════════════════════════════════════════════════════
step 2 "Checking GPU availability in ${GKE_REGION}"

echo -e "${DIM}Scanning zones for ${GPU_ACCEL} capacity...${NC}"
AVAILABLE_ZONES=()
for zone in $(gcloud compute zones list --filter="region:${GKE_REGION} AND status=UP" --format="value(name)" --project="${GCP_PROJECT}" 2>/dev/null); do
  if gcloud compute accelerator-types describe "${GPU_ACCEL}" --zone="${zone}" --project="${GCP_PROJECT}" &>/dev/null; then
    AVAILABLE_ZONES+=("${zone}")
    echo -e "  ${GREEN}✓${NC} ${zone} — ${GPU_ACCEL} available"
  else
    echo -e "  ${DIM}✗ ${zone} — no ${GPU_ACCEL}${NC}"
  fi
done

if [ ${#AVAILABLE_ZONES[@]} -eq 0 ]; then
  echo ""
  warn "No zones in ${GKE_REGION} have ${GPU_ACCEL}."
  echo ""
  echo "Try a different region. Common GPU regions:"
  echo "  A100: us-central1, us-east1, us-west1, europe-west4"
  echo "  L4:   us-central1, us-east1, us-west1, us-west4, europe-west1"
  echo ""
  echo "Re-run with: GKE_REGION=us-west1 ./deploy.sh"
  exit 1
fi

echo ""
ok "Found ${GPU_ACCEL} in ${#AVAILABLE_ZONES[@]} zone(s): ${AVAILABLE_ZONES[*]}"
echo -e "${DIM}The regional cluster + ComputeClass will auto-select the best zone.${NC}"

# ══════════════════════════════════════════════════════════════════════════════
# Step 3: Create Regional GKE Cluster
# ══════════════════════════════════════════════════════════════════════════════
step 3 "Creating regional GKE cluster '${GKE_CLUSTER}'"

if gcloud container clusters describe "${GKE_CLUSTER}" --region="${GKE_REGION}" --project="${GCP_PROJECT}" &>/dev/null; then
  warn "Cluster '${GKE_CLUSTER}' already exists — skipping creation"
else
  # Build --node-locations flag from available GPU zones (max 3)
  NODE_LOCATIONS=$(echo "${AVAILABLE_ZONES[@]}" | tr ' ' '\n' | head -3 | tr '\n' ',' | sed 's/,$//')

  gcloud container clusters create "${GKE_CLUSTER}" \
    --project="${GCP_PROJECT}" \
    --region="${GKE_REGION}" \
    --node-locations="${NODE_LOCATIONS}" \
    --release-channel=regular \
    --machine-type="e2-standard-4" \
    --num-nodes=1 \
    --enable-autoscaling --min-nodes=0 --max-nodes=3 \
    --disk-size=50 \
    --disk-type=pd-standard \
    --enable-ip-alias \
    --workload-pool="${GCP_PROJECT}.svc.id.goog" \
    --logging=SYSTEM,WORKLOAD \
    --monitoring=SYSTEM \
    --enable-autoprovisioning \
    --min-cpu=0 --max-cpu=96 \
    --min-memory=0 --max-memory=384 \
    --min-accelerator="type=${GPU_ACCEL},count=0" \
    --max-accelerator="type=${GPU_ACCEL},count=4" \
    --autoprovisioning-scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring
  ok "Regional cluster created with NAP enabled (gVisor via runtimeClassName on pods)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 4: Get Credentials
# ══════════════════════════════════════════════════════════════════════════════
step 4 "Configuring kubectl"
gcloud container clusters get-credentials "${GKE_CLUSTER}" \
  --project="${GCP_PROJECT}" \
  --region="${GKE_REGION}"
ok "kubectl connected to ${GKE_CLUSTER}"

echo ""
echo "Cluster nodes:"
kubectl get nodes -o wide
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Step 5: Apply ComputeClass (automatic GPU zone selection)
# ══════════════════════════════════════════════════════════════════════════════
step 5 "Creating ComputeClass for ${GPU_ACCEL}"

# ComputeClass defines GPU provisioning priorities.
# GKE evaluates top-to-bottom: try Spot first (if enabled), then on-demand.
# NAP creates node pools automatically in whichever zone has capacity.
if [[ "${NEMOKUBE_SPOT}" == "yes" ]]; then
cat <<EOCC | kubectl apply -f -
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: nemokube-gpu
spec:
  priorities:
    - machineFamily: ${GPU_MACHINE_TYPE%%-*}
      spot: true
      gpu:
        type: ${GPU_ACCEL}
        count: 1
    - machineFamily: ${GPU_MACHINE_TYPE%%-*}
      spot: false
      gpu:
        type: ${GPU_ACCEL}
        count: 1
  nodePoolAutoCreation:
    enabled: true
  activeMigration:
    optimizeRulePriority: true
EOCC
else
cat <<EOCC | kubectl apply -f -
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: nemokube-gpu
spec:
  priorities:
    - machineFamily: ${GPU_MACHINE_TYPE%%-*}
      spot: false
      gpu:
        type: ${GPU_ACCEL}
        count: 1
  nodePoolAutoCreation:
    enabled: true
  activeMigration:
    optimizeRulePriority: true
EOCC
fi
ok "ComputeClass 'nemokube-gpu' applied"

# ══════════════════════════════════════════════════════════════════════════════
# Step 6: Install NVIDIA GPU Drivers
# ══════════════════════════════════════════════════════════════════════════════
step 6 "Installing NVIDIA GPU driver daemonset"
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nvidia-driver-installer/cos/daemonset-preloaded-latest.yaml 2>/dev/null || true
ok "GPU drivers installing (will activate when GPU node joins)"

# ══════════════════════════════════════════════════════════════════════════════
# Step 7: Build & Push Sandbox Image
# ══════════════════════════════════════════════════════════════════════════════
step 7 "Building NemoClaw sandbox image"

# Create Artifact Registry repo
gcloud artifacts repositories create "${AR_REPO}" \
  --project="${GCP_PROJECT}" \
  --repository-format=docker \
  --location="${GKE_REGION}" \
  --description="NemoClaw container images" 2>/dev/null || true

# Auth Docker to Artifact Registry
gcloud auth configure-docker "${GKE_REGION}-docker.pkg.dev" --quiet

# Clone and build
TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT
echo "Cloning NemoClaw..."
git clone --depth 1 https://github.com/NVIDIA/NemoClaw.git "${TMPDIR}/NemoClaw"
cd "${TMPDIR}/NemoClaw"

echo "Building Docker image..."
docker build -t "${SANDBOX_IMAGE}:${IMAGE_TAG}" .
docker tag "${SANDBOX_IMAGE}:${IMAGE_TAG}" "${FULL_IMAGE}"

echo "Pushing to Artifact Registry..."
docker push "${FULL_IMAGE}"
ok "Image pushed: ${FULL_IMAGE}"
cd -

# ══════════════════════════════════════════════════════════════════════════════
# Step 8: Create Namespace & Secrets
# ══════════════════════════════════════════════════════════════════════════════
step 8 "Creating namespace and secrets"
kubectl create namespace nemokube 2>/dev/null || true
kubectl -n nemokube delete secret nemokube-secrets 2>/dev/null || true
kubectl -n nemokube create secret generic nemokube-secrets \
  --from-literal=NVIDIA_API_KEY="${NVIDIA_API_KEY}" \
  --from-literal=TELEGRAM_BOT_TOKEN=""
ok "Namespace and secrets created"

# Create NVIDIA registry pull secret (nvcr.io requires authentication)
kubectl -n nemokube delete secret nvcr-pull-secret 2>/dev/null || true
kubectl -n nemokube create secret docker-registry nvcr-pull-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password="${NVIDIA_API_KEY}"
ok "NVIDIA registry pull secret created"

# ══════════════════════════════════════════════════════════════════════════════
# Step 9: Apply ConfigMap
# ══════════════════════════════════════════════════════════════════════════════
step 9 "Applying ConfigMap"
cat <<EOCM | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: nemokube-config
  namespace: nemokube
data:
  INFERENCE_PROFILE: "nim-local"
  INFERENCE_MODEL: "${NIM_MODEL}"
  NIM_ENDPOINT: "http://nim-service.nemokube.svc.cluster.local:8000/v1"
  PUBLIC_PORT: "18789"
  CHAT_UI_URL: "http://localhost:18789"
EOCM
ok "ConfigMap applied"

# ══════════════════════════════════════════════════════════════════════════════
# Step 10: Deploy NIM Inference
# ══════════════════════════════════════════════════════════════════════════════
step 10 "Deploying NIM inference server (${NIM_MODEL})"
cat <<EONIM | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nim-model-cache
  namespace: nemokube
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: premium-rwo
  resources:
    requests:
      storage: ${NIM_PVC_SIZE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nim-inference
  namespace: nemokube
  labels:
    app.kubernetes.io/name: nim-inference
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: nim-inference
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nim-inference
    spec:
      runtimeClassName: gvisor
      nodeSelector:
        cloud.google.com/compute-class: nemokube-gpu
      imagePullSecrets:
        - name: nvcr-pull-secret
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
        - key: "cloud.google.com/compute-class"
          operator: "Equal"
          value: "nemokube-gpu"
          effect: "NoSchedule"
      initContainers:
        - name: fix-cache-perms
          image: busybox:latest
          command: ["sh", "-c", "chmod -R 777 /opt/nim/.cache"]
          volumeMounts:
            - name: model-cache
              mountPath: /opt/nim/.cache
      containers:
        - name: nim
          image: ${NIM_IMAGE}
          ports:
            - name: http
              containerPort: 8000
          env:
            - name: NGC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: nemokube-secrets
                  key: NVIDIA_API_KEY
            - name: NVIDIA_API_KEY
              valueFrom:
                secretKeyRef:
                  name: nemokube-secrets
                  key: NVIDIA_API_KEY
            - name: NIM_MAX_MODEL_LEN
              value: "16384"
            - name: NIM_GPU_MEMORY_UTILIZATION
              value: "0.90"
            - name: NIM_TENSOR_PARALLEL_SIZE
              value: "1"
          resources:
            requests:
              cpu: "4"
              memory: "${NIM_MEM}"
              nvidia.com/gpu: "1"
            limits:
              cpu: "8"
              memory: "${NIM_MEM}"
              nvidia.com/gpu: "1"
          volumeMounts:
            - name: model-cache
              mountPath: /opt/nim/.cache
          startupProbe:
            httpGet:
              path: /v1/health/ready
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 90
          readinessProbe:
            httpGet:
              path: /v1/health/ready
              port: http
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /v1/health/live
              port: http
            periodSeconds: 30
      volumes:
        - name: model-cache
          persistentVolumeClaim:
            claimName: nim-model-cache
---
apiVersion: v1
kind: Service
metadata:
  name: nim-service
  namespace: nemokube
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: nim-inference
  ports:
    - name: http
      port: 8000
      targetPort: http
EONIM
ok "NIM deployment applied — NAP will auto-provision a GPU node"

# ══════════════════════════════════════════════════════════════════════════════
# Step 11: Deploy NemoClaw Sandbox
# ══════════════════════════════════════════════════════════════════════════════
step 11 "Deploying NemoClaw sandbox"
cat <<EOSB | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: nemokube
  namespace: nemokube
  labels:
    app.kubernetes.io/name: nemokube
spec:
  serviceName: nemokube-headless
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: nemokube
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nemokube
    spec:
      runtimeClassName: gvisor
      initContainers:
        - name: setup
          image: ${FULL_IMAGE}
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -e
              python3 - <<'PYSETUP'
              import json, os
              home = os.environ.get('HOME', '/sandbox')
              config_path = os.path.join(home, '.openclaw', 'openclaw.json')
              os.makedirs(os.path.dirname(config_path), exist_ok=True)
              nim_endpoint = os.environ.get('NIM_ENDPOINT', 'http://nim-service.nemokube.svc.cluster.local:8000/v1')
              model = os.environ.get('INFERENCE_MODEL', 'nvidia/nemotron-3-nano')
              cfg = {
                  'agents': {'defaults': {'model': {'primary': model}}},
                  'models': {'mode': 'merge', 'providers': {'nim-local': {
                      'baseUrl': nim_endpoint,
                      'apiKey': os.environ.get('NVIDIA_API_KEY', 'nim-local'),
                      'api': 'openai-completions',
                      'models': [{'id': model.split('/')[-1], 'name': model, 'reasoning': False,
                                   'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
                                   'contextWindow': 131072, 'maxTokens': 8192}]
                  }}},
                  'gateway': {'mode': 'local', 'controlUi': {
                      'allowInsecureAuth': True, 'dangerouslyDisableDeviceAuth': True,
                      'allowedOrigins': ['http://127.0.0.1:18789', 'http://localhost:18789']},
                      'trustedProxies': ['127.0.0.1', '::1']},
              }
              with open(config_path, 'w') as f:
                  json.dump(cfg, f, indent=2)
              os.chmod(config_path, 0o600)
              PYSETUP
          env:
            - name: NVIDIA_API_KEY
              valueFrom:
                secretKeyRef:
                  name: nemokube-secrets
                  key: NVIDIA_API_KEY
            - name: NIM_ENDPOINT
              valueFrom:
                configMapKeyRef:
                  name: nemokube-config
                  key: NIM_ENDPOINT
            - name: INFERENCE_MODEL
              valueFrom:
                configMapKeyRef:
                  name: nemokube-config
                  key: INFERENCE_MODEL
          volumeMounts:
            - name: sandbox-data
              mountPath: /sandbox
      containers:
        - name: nemokube-sandbox
          image: ${FULL_IMAGE}
          command: ["/bin/bash", "-c"]
          args:
            - |
              # Run NemoClaw setup (configures plugins, auth, etc.)
              # Pass no args so it backgrounds the gateway, then we fix config and restart
              /usr/local/bin/nemoclaw-start &
              SETUP_PID=\$!
              wait \$SETUP_PID 2>/dev/null || true
              sleep 2
              # nemoclaw-start hardcodes nvidia/nemotron-3-super-120b — fix to actual NIM model
              python3 -c "
              import json, os
              path = os.path.expanduser('~/.openclaw/openclaw.json')
              cfg = json.load(open(path))
              model = os.environ.get('INFERENCE_MODEL', 'meta/llama-3.1-8b-instruct')
              cfg['agents']['defaults']['model']['primary'] = model
              nim_endpoint = os.environ.get('NIM_ENDPOINT', 'http://nim-service.nemokube.svc.cluster.local:8000/v1')
              nim = cfg.setdefault('models', {}).setdefault('providers', {}).setdefault('nim-local', {})
              nim['baseUrl'] = nim_endpoint
              nim['apiKey'] = os.environ.get('NVIDIA_API_KEY', 'nim-local')
              nim['api'] = 'openai-completions'
              short = model.split('/')[-1]
              nim['models'] = [{'id': short, 'name': model, 'reasoning': False,
                'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
                'contextWindow': 131072, 'maxTokens': 8192}]
              json.dump(cfg, open(path, 'w'), indent=2)
              print(f'[nemokube] Model fixed to {model} via {nim_endpoint}')
              "
              # Stop the backgrounded gateway and relaunch in foreground
              openclaw gateway stop 2>/dev/null || true
              sleep 1
              exec openclaw gateway run
          ports:
            - name: dashboard
              containerPort: 18789
          env:
            - name: NVIDIA_API_KEY
              valueFrom:
                secretKeyRef:
                  name: nemokube-secrets
                  key: NVIDIA_API_KEY
            - name: CHAT_UI_URL
              valueFrom:
                configMapKeyRef:
                  name: nemokube-config
                  key: CHAT_UI_URL
            - name: PUBLIC_PORT
              valueFrom:
                configMapKeyRef:
                  name: nemokube-config
                  key: PUBLIC_PORT
            - name: NIM_ENDPOINT
              valueFrom:
                configMapKeyRef:
                  name: nemokube-config
                  key: NIM_ENDPOINT
            - name: INFERENCE_MODEL
              valueFrom:
                configMapKeyRef:
                  name: nemokube-config
                  key: INFERENCE_MODEL
          resources:
            requests:
              cpu: "1"
              memory: "2Gi"
            limits:
              cpu: "2"
              memory: "4Gi"
          volumeMounts:
            - name: sandbox-data
              mountPath: /sandbox
          readinessProbe:
            tcpSocket:
              port: dashboard
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: dashboard
            initialDelaySeconds: 30
            periodSeconds: 30
      volumes:
        - name: sandbox-data
          emptyDir:
            sizeLimit: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: nemokube-headless
  namespace: nemokube
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: nemokube
  ports:
    - name: dashboard
      port: 18789
      targetPort: dashboard
---
apiVersion: v1
kind: Service
metadata:
  name: nemokube-dashboard
  namespace: nemokube
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: nemokube
  ports:
    - name: http
      port: 80
      targetPort: dashboard
EOSB
ok "NemoClaw sandbox deployed"

# ══════════════════════════════════════════════════════════════════════════════
# Step 12: Apply Network Policies
# ══════════════════════════════════════════════════════════════════════════════
step 12 "Applying NetworkPolicies"
cat <<EONP | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: nim-inference-ingress
  namespace: nemokube
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: nim-inference
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: nemokube
      ports:
        - protocol: TCP
          port: 8000
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: nemokube-sandbox-policy
  namespace: nemokube
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: nemokube
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - ports:
        - protocol: TCP
          port: 18789
  egress:
    - ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: nim-inference
      ports:
        - protocol: TCP
          port: 8000
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - protocol: TCP
          port: 443
EONP
ok "Network policies applied"

# ══════════════════════════════════════════════════════════════════════════════
# Step 13: Wait for NIM to be ready
# ══════════════════════════════════════════════════════════════════════════════
step 13 "Waiting for NIM (NAP provisions GPU node → pulls image → loads model)"
echo "This takes 5-15 min depending on GPU availability and model size."
echo ""

# Wait for the pod to exist first
for i in $(seq 1 60); do
  NIM_POD=$(kubectl -n nemokube get pods -l app.kubernetes.io/name=nim-inference -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && break
  sleep 5
done

if [ -n "${NIM_POD:-}" ]; then
  # Show logs but don't block — timeout after 15 minutes
  timeout 900 kubectl -n nemokube logs -f "pod/${NIM_POD}" --tail=50 2>/dev/null &
  LOG_PID=$!

  # Poll readiness
  for i in $(seq 1 180); do
    READY=$(kubectl -n nemokube get deployment nim-inference -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [ "${READY:-0}" -ge 1 ]; then
      kill $LOG_PID 2>/dev/null || true
      ok "NIM inference is ready!"
      break
    fi
    sleep 5
  done

  if [ "${READY:-0}" -lt 1 ]; then
    kill $LOG_PID 2>/dev/null || true
    warn "NIM not ready after 15 min — check: kubectl -n nemokube logs deploy/nim-inference"
    warn "NAP may still be provisioning a GPU node. Check: kubectl get nodes -o wide"
  fi
else
  warn "NIM pod not found — NAP may still be provisioning. Check: kubectl -n nemokube get pods"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 14: Verify NemoClaw
# ══════════════════════════════════════════════════════════════════════════════
step 14 "Checking NemoClaw sandbox"
for i in $(seq 1 30); do
  NC_READY=$(kubectl -n nemokube get statefulset nemokube -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [ "${NC_READY:-0}" -ge 1 ]; then
    ok "NemoClaw sandbox is running!"
    break
  fi
  sleep 5
done

echo ""
echo "All pods:"
kubectl -n nemokube get pods -o wide
echo ""
echo "Nodes:"
kubectl get nodes -o wide
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                    Deployment Complete!                   ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║                                                           ║"
echo "║  Access the dashboard:                                    ║"
echo "║    kubectl -n nemokube port-forward svc/nemokube-dashboard 18789:80"
echo "║    Then open: http://localhost:18789                      ║"
echo "║                                                           ║"
echo "║  Shell into sandbox:                                      ║"
echo "║    kubectl -n nemokube exec -it nemokube-0 -- /bin/bash   ║"
echo "║                                                           ║"
echo "║  Test inference:                                          ║"
echo "║    kubectl -n nemokube exec -it nemokube-0 -- \\           ║"
echo "║      openclaw agent --agent main --local \\                ║"
echo "║        -m 'Hello from GKE!' --session-id test             ║"
echo "║                                                           ║"
echo "║  View NIM logs:                                           ║"
echo "║    kubectl -n nemokube logs -f deploy/nim-inference        ║"
echo "║                                                           ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
