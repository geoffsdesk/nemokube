# NemoKube

One-command deployment of [NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw) on Google Kubernetes Engine with capacity-aware GPU provisioning via NVIDIA NIM.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  GKE Regional Cluster                                       │
│  (auto-selects zone with GPU capacity via ComputeClass)     │
│                                                             │
│  ┌──────────────────────┐    ┌───────────────────────────┐  │
│  │  NemoClaw Sandbox    │    │  NIM Inference (GPU)      │  │
│  │  ┌────────────────┐  │    │                           │  │
│  │  │ OpenClaw Agent  │──┼───▶  Your selected model      │  │
│  │  │                 │  │    │  OpenAI-compat API :8000  │  │
│  │  └────────────────┘  │    └───────────────────────────┘  │
│  │  ┌────────────────┐  │                                   │
│  │  │ Dashboard :18789│  │    ┌───────────────────────────┐  │
│  │  └────────────────┘  │    │  Model Cache PVC          │  │
│  └──────────────────────┘    └───────────────────────────┘  │
│                                                             │
│  ComputeClass ──▶ NAP auto-provisions GPU node pool         │
│  Pre-flight   ──▶ Scans zones for GPU availability          │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- **gcloud CLI** installed and authenticated
- **kubectl** installed
- **Docker** installed locally
- **NVIDIA API key** from [build.nvidia.com](https://build.nvidia.com) (must accept model license)
- GCP project with billing enabled and GPU quota > 0

## Quick Start

```bash
export GCP_PROJECT="your-gcp-project-id"
export NVIDIA_API_KEY="nvapi-your-key-here"
chmod +x deploy.sh && ./deploy.sh
```

The script walks you through model selection, checks GPU availability across zones, creates a regional GKE cluster with Node Auto-Provisioning, and deploys everything. No more manual zone-hunting for GPUs.

## What's Different: Capacity-Aware Provisioning

Previous versions used zonal clusters, which locked you into a single zone. If that zone had no GPU capacity, you were stuck deleting and recreating infrastructure. NemoKube v2 fixes this with three changes:

**Pre-flight check (Step 2)** scans all zones in your region for the required GPU type before creating anything. If no zones have capacity, it tells you immediately and suggests alternative regions. No more "create and pray."

**Regional cluster (Step 3)** spans multiple zones. The control plane is highly available and node pools can be created in any zone within the region.

**ComputeClass + NAP (Step 5)** defines your GPU requirements as a declarative resource. GKE's Node Auto-Provisioning evaluates real-time capacity across zones and automatically creates a node pool wherever GPUs are available. If Spot is enabled, it tries Spot first and falls back to on-demand.

## Model Selection

The deploy script includes an interactive model selection wizard:

```
  #  Model                        VRAM    GPU          Est. Cost
  ─  ─────────────────────────    ─────   ──────────   ──────────
  1  Nemotron Nano 30B (rec.)     24GB    A100 (40GB)  $3.67/hr
  2  Nemotron Super 49B           24GB    A100 (40GB)  $3.67/hr
  3  Nemotron Super 120B          40GB    A100 (40GB)  $3.67/hr
  4  Llama 3.1 8B (lightweight)   16GB    L4 (24GB)    $0.70/hr
```

VRAM values are verified runtime requirements (not checkpoint sizes). The Nano 30B needs ~23GB at runtime, which exceeds the L4's usable 22GB — it requires an A100. The Llama 8B is the only model that fits on an L4.

To skip the interactive prompt:

```bash
NEMOKUBE_MODEL=1 ./deploy.sh   # Nano 30B
NEMOKUBE_MODEL=4 ./deploy.sh   # Llama 8B
```

## Spot VM Support

The deploy script offers a Spot VM option for the GPU node pool, which reduces costs by 60-70%. Spot VMs can be preempted, but model weights are cached on a PVC that survives preemption. NIM reloads from cache in ~2-3 minutes instead of 8+ minutes cold.

The ComputeClass handles Spot gracefully: when enabled, it tries Spot first and automatically falls back to on-demand if Spot capacity is unavailable.

```bash
NEMOKUBE_SPOT=yes ./deploy.sh   # Spot (with on-demand fallback)
NEMOKUBE_SPOT=no  ./deploy.sh   # On-demand only
```

## Machine Type Override

Override the default machine type if you have pre-existing quota:

```bash
GPU_MACHINE_TYPE=a2-highgpu-1g ./deploy.sh
```

## Region Selection

The default region is `us-central1`. To use a different region:

```bash
GKE_REGION=us-west1 ./deploy.sh
```

Common regions with GPU availability: `us-central1`, `us-east1`, `us-west1`, `europe-west4` (A100), `us-west4`, `europe-west1` (L4).

## Fully Non-Interactive Deployment

All prompts can be skipped with environment variables:

```bash
export GCP_PROJECT="my-project"
export NVIDIA_API_KEY="nvapi-..."
export NEMOKUBE_MODEL=1
export NEMOKUBE_SPOT=yes
export GKE_REGION=us-west1
./deploy.sh
```

## After Deployment

Access the dashboard:

```bash
kubectl -n nemokube port-forward svc/nemokube-dashboard 18789:80
# Open http://localhost:18789
```

Shell into the sandbox:

```bash
kubectl -n nemokube exec -it nemokube-0 -- /bin/bash
openclaw agent --agent main --local -m "Hello from GKE!" --session-id test
```

## Inference Profiles

Defaults to **nim-local** (in-cluster GPU inference via NIM). To use NVIDIA cloud inference instead (no GPU needed):

```bash
kubectl -n nemokube edit configmap nemokube-config
# Set INFERENCE_PROFILE: "default"
```

## File Layout

```
nemokube/
├── deploy.sh                         # One-command deployment (v2)
├── scripts/
│   ├── 01-create-gke-cluster.sh      # Standalone cluster creation
│   └── 02-build-and-push-image.sh    # Standalone image build
├── manifests/
│   ├── 00-namespace.yaml
│   ├── 01-secrets.yaml
│   ├── 02-configmap.yaml
│   ├── 03-nim-deployment.yaml
│   ├── 04-nemoclaw-deployment.yaml
│   └── 05-networkpolicy.yaml
└── README.md
```

## Troubleshooting

**"No zones in REGION have GPU_TYPE"** — Try a different region: `GKE_REGION=us-west1 ./deploy.sh`

**ImagePullBackOff on NIM** — Make sure you've accepted the model license at [build.nvidia.com](https://build.nvidia.com). Search for the model name and click "Get Access."

**CUDA out of memory** — The model doesn't fit on your GPU. The Nano 30B needs A100 (40GB), not L4 (24GB). Check the model table above.

**GPU quota exceeded** — Request quota increase at IAM & Admin > Quotas. Search for "GPUs (all regions)" under Compute Engine API. You need at least 1.

## Notes

- NemoClaw is alpha software (GTC 2026). APIs are evolving.
- VRAM sizes are runtime measurements, not checkpoint sizes on disk.
- For production, replace K8s Secrets with GKE Workload Identity + Secret Manager.
- Costs are estimates for `us-central1`. Pricing varies by region.
- The `NGC_API_KEY` env var is required by NIM containers (set automatically from your NVIDIA_API_KEY).
