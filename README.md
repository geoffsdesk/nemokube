# NemoKube

One-command deployment of [NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw) on Google Cloud with NIM inference. Two deployment options: **Cloud Run** (serverless, scale-to-zero) or **GKE** (Kubernetes, always-on).

> **Disclaimer:** This is a personal project. It is not supported, endorsed, or affiliated with Google or NVIDIA. Written against NemoClaw alpha (GTC 2026) — the project is maintained informally and may not reflect the latest releases.

## Choose Your Deployment

| | Cloud Run | GKE |
|---|---|---|
| **Best for** | Dev/test, intermittent use | Production, always-on |
| **Idle cost** | $0 (scales to zero) | ~$330/mo |
| **Cold start** | 30-120s (model loading) | None |
| **Setup** | 2 gcloud commands | Cluster + NAP + ComputeClass |
| **GPU quota** | Auto-granted (no request) | Must request manually |
| **GPU options** | L4 only | L4, A100, H100 |
| **Security** | HTTPS + token auth | gVisor (GKE Sandbox) + NetworkPolicy |
| **Script** | `deploy-cloudrun.sh` | `deploy.sh` |

## Quick Start: Cloud Run

> **Work in Progress:** The Cloud Run deployment is under active development. The NIM inference service deploys and runs correctly, but the gateway service has unresolved issues with NemoClaw's config reload behavior causing WebSocket disconnects. Use the GKE deployment for a fully working setup.

```bash
export GCP_PROJECT="your-gcp-project-id"
export NVIDIA_API_KEY="nvapi-your-key-here"
chmod +x deploy-cloudrun.sh && ./deploy-cloudrun.sh
```

Two Cloud Run services deploy: NIM inference with an L4 GPU, and the NemoClaw gateway on CPU. Both scale to zero when idle.

**Estimated cost:** ~$0/hr idle, ~$1.65/hr active.

### Cleanup

```bash
./destroy-cloudrun.sh
# or manually:
gcloud run services delete nim-inference --region=$REGION --project=$GCP_PROJECT -q
gcloud run services delete nemokube-gateway --region=$REGION --project=$GCP_PROJECT -q
```

## Quick Start: GKE (Recommended)

```bash
export GCP_PROJECT="your-gcp-project-id"
export NVIDIA_API_KEY="nvapi-your-key-here"
chmod +x deploy.sh && ./deploy.sh
```

Creates a regional GKE cluster with Node Auto-Provisioning, deploys NIM on a GPU node via ComputeClass, and launches the NemoClaw agent sandbox. The script walks you through model selection and checks GPU availability across zones.

**Estimated cost:** ~$330/mo on-demand, ~$190/mo with Spot VMs.

### Cleanup

```bash
./destroy-gke.sh
# or manually:
gcloud container clusters delete nemokube-cluster --region=$GKE_REGION --project=$GCP_PROJECT -q
```

## Architecture

### Cloud Run

```
┌────────────────────────────┐     ┌────────────────────────────┐
│  nemokube-gateway          │     │  nim-inference              │
│  (CPU, scale-to-zero)      │────▶│  (L4 GPU, scale-to-zero)   │
│  OpenClaw Agent + Dashboard │     │  NIM + Llama 3.1 8B        │
│  Public HTTPS URL           │     │  Internal (IAM-gated)      │
└────────────────────────────┘     └────────────────────────────┘
```

### GKE

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
- **Docker** installed locally
- **NVIDIA API key** from [build.nvidia.com](https://build.nvidia.com) (must accept model license)
- GCP project with billing enabled
- **kubectl** (GKE only)
- GPU quota > 0 (GKE only — Cloud Run auto-grants L4 quota)

## Model Selection

### Cloud Run (L4 GPU only)

```
  #  Model                    CPU   Memory   GPU    Est. Cost
  ─  ────────────────────     ───   ──────   ────   ──────────
  1  Llama 3.1 8B (rec.)     8     32 GiB   L4     ~$1.65/hr
  2  Llama 3.1 8B (minimal)  4     16 GiB   L4     ~$0.90/hr
```

### GKE (L4 or A100)

```
  #  Model                        VRAM    GPU          Est. Cost
  ─  ─────────────────────────    ─────   ──────────   ──────────
  1  Nemotron Nano 30B (rec.)     24GB    A100 (40GB)  $3.67/hr
  2  Nemotron Super 49B           24GB    A100 (40GB)  $3.67/hr
  3  Nemotron Super 120B          40GB    A100 (40GB)  $3.67/hr
  4  Llama 3.1 8B (lightweight)   16GB    L4 (24GB)    $0.70/hr
```

VRAM values are verified runtime requirements (not checkpoint sizes). The Nemotron Nano 30B needs ~23GB at runtime — it does **not** fit on an L4 despite NVIDIA listing it as 8GB.

## GKE-Specific Features

### gVisor (GKE Sandbox)

The NemoClaw sandbox pod runs with `runtimeClassName: gvisor`, using GKE Sandbox for kernel-level isolation. This provides an additional security layer by intercepting system calls through gVisor's user-space kernel, preventing container escapes even if the application is compromised. The NIM inference pod runs without gVisor because NIM's CUDA/PyTorch stack requires direct GPU driver access that gVisor's virtualized driver (reported as version 12020) doesn't satisfy. The NIM pod is protected by NetworkPolicy instead, restricting ingress to only the NemoClaw sandbox.

### ComputeClass + NAP

The GKE deployment uses ComputeClass to declare GPU requirements as a Kubernetes resource. Node Auto-Provisioning (NAP) evaluates capacity across zones and creates node pools automatically. No manual zone selection needed.

### Spot VM Support

```bash
NEMOKUBE_SPOT=yes ./deploy.sh   # Spot first, on-demand fallback
```

60-70% cheaper. Model weights are cached on a PVC that survives preemption.

### Region Override

```bash
GKE_REGION=us-west1 ./deploy.sh        # GKE
REGION=asia-southeast1 ./deploy-cloudrun.sh  # Cloud Run
```

### Non-Interactive Deployment

```bash
export GCP_PROJECT="my-project"
export NVIDIA_API_KEY="nvapi-..."
export NEMOKUBE_MODEL=4
export NEMOKUBE_SPOT=no
./deploy.sh  # GKE — no prompts
```

```bash
export GCP_PROJECT="my-project"
export NVIDIA_API_KEY="nvapi-..."
export NEMOKUBE_MODEL=1
./deploy-cloudrun.sh  # Cloud Run — no prompts
```

## After Deployment

### Cloud Run

Open the gateway URL printed at the end of deployment. Get the auth token from the logs:

```bash
gcloud run services logs read nemokube-gateway \
  --project=$GCP_PROJECT --region=$REGION --limit=100 | grep token
```

### GKE

```bash
kubectl -n nemokube port-forward svc/nemokube-dashboard 18789:80
# Open http://localhost:18789
```

## File Layout

```
nemokube/
├── deploy.sh                     # GKE deployment (Kubernetes) — recommended
├── deploy-cloudrun.sh            # Cloud Run deployment [WIP]
├── destroy-gke.sh                # Tear down GKE resources
├── destroy-cloudrun.sh           # Tear down Cloud Run resources
├── Dockerfile.gateway            # Cloud Run gateway image [WIP]
├── gateway-start.sh              # Cloud Run gateway entrypoint [WIP]
├── scripts/
│   ├── 01-create-gke-cluster.sh  # Standalone cluster creation (gVisor enabled)
│   └── 02-build-and-push-image.sh
├── manifests/                    # GKE Kubernetes manifests
│   ├── 00-namespace.yaml
│   ├── 01-secrets.yaml
│   ├── 02-configmap.yaml
│   ├── 03-nim-deployment.yaml    # NIM inference (gVisor + GPU)
│   ├── 04-nemoclaw-deployment.yaml  # NemoClaw sandbox (gVisor)
│   └── 05-networkpolicy.yaml
├── docs/
│   ├── NemoClaw_on_CloudRun_Guide.docx
│   ├── NemoClaw_on_GKE_Guide.docx
│   ├── GKE_GPU_Friction_Log_v2.docx
│   └── GKE_GPU_Friction_Log.docx
└── README.md
```

## Troubleshooting

**Cloud Run: "Service unavailable" on first request** — Both services scaled to zero. Wait 30-120 seconds for the cold start (GPU init + model loading).

**Cloud Run: "too many failed auth attempts"** — Redeploy the gateway to reset the rate limiter.

**GKE: "No zones in REGION have GPU_TYPE"** — Try a different region: `GKE_REGION=us-west1 ./deploy.sh`

**GKE: ImagePullBackOff on NIM** — Accept the model license at [build.nvidia.com](https://build.nvidia.com).

**CUDA out of memory** — The model doesn't fit. Nemotron Nano 30B needs A100 (40GB), not L4 (24GB).

**GPU quota exceeded (GKE only)** — Request increase at IAM & Admin > Quotas > "GPUs (all regions)". Cloud Run auto-grants L4 quota.

**Context overflow** — NIM's default 16K context is too small for NemoClaw. Both deploy scripts set `NIM_MAX_MODEL_LEN=32768`.

**Model 404** — NemoClaw strips the provider prefix from model names. Both deploy scripts set `NIM_SERVED_MODEL_NAME` to work around this.

## Known NemoClaw Workarounds

These are specific to NemoClaw alpha (March 2026) and are handled automatically by both deploy scripts:

| Issue | Cause | Fix Applied |
|---|---|---|
| Gateway exits in containers | `nemoclaw-start` backgrounds the gateway | Custom entrypoint with `exec openclaw gateway run` |
| Config overwritten on restart | Hardcodes nemotron-3-super-120b | Config patched after setup, before gateway start |
| Model 404 from NIM | OpenClaw strips provider prefix | `NIM_SERVED_MODEL_NAME` set to short name |
| Context overflow | NIM defaults to 16K context | `NIM_MAX_MODEL_LEN=32768` |
| Origin rejected | localhost vs 127.0.0.1 mismatch | Both origins in allowedOrigins config |
| Gateway binds localhost only | Cloud Run needs 0.0.0.0 | Node.js reverse proxy on :8080 [WIP] |
| Config reload restarts gateway | Plugin load + config patch trigger SIGUSR1 | Two-phase config patch [WIP] |

## Notes

- NemoClaw is alpha software (GTC 2026). APIs are evolving.
- VRAM sizes are runtime measurements, not checkpoint sizes.
- This is a personal project — not supported by Google or NVIDIA.
- Costs are estimates for `us-central1`. Pricing varies by region.
- For production GKE, replace K8s Secrets with Workload Identity + Secret Manager.
