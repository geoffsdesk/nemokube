# NemoKube

> **This project is experimental, a work in progress, and not supported by Google or NVIDIA.** It exists to explore what it takes to run NemoClaw's security model on GKE using Kubernetes-native primitives. Expect rough edges, breaking changes, and incomplete features. Written against NemoClaw alpha (GTC 2026).

NemoClaw's security model, translated for Kubernetes. One-command deployment of [NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw) on Google Cloud with NIM inference, implementing Landlock filesystem isolation, credential separation, seccomp filtering, and deny-default NetworkPolicy.

Two deployment options: **GKE** (recommended, full security stack) or **Cloud Run** (WIP, serverless).

## Other Approaches to NemoClaw on Kubernetes

NemoKube is one of several ways to run NemoClaw in a Kubernetes environment. Before choosing this approach, you should be aware of the alternatives:

**NVIDIA's official method (nested containers):** The [NemoClaw repository](https://github.com/NVIDIA/NemoClaw) runs OpenShell inside a Kubernetes pod, effectively nesting container management within K8s. This preserves the full OpenShell runtime (including its native Landlock, seccomp, and credential management) at the cost of requiring privileged pods or sysbox for nested container support. If your cluster allows privileged workloads, this is the most faithful way to run NemoClaw on K8s.

**gVisor variant (under testing):** A separate branch of this project is exploring [GKE Sandbox (gVisor)](https://cloud.google.com/kubernetes-engine/docs/concepts/sandbox-pods) as an alternative isolation layer. gVisor provides a user-space kernel that intercepts syscalls, offering strong sandbox isolation without Landlock. However, gVisor is currently incompatible with both NIM's CUDA/PyTorch stack (gVisor reports a GPU driver version that NIM considers too old) and NemoClaw's gateway (which binds to 127.0.0.1, causing kubelet health probes to fail under gVisor's network namespace). The manifests include commented-out `runtimeClassName: gvisor` for future re-enablement as these compatibility issues are resolved.

**NemoKube's approach (K8s-native translation):** This repo translates NemoClaw's security layers into Kubernetes-native primitives: real Landlock syscalls via a custom seccomp profile, credential isolation via an inference proxy pod, and deny-default NetworkPolicy. No nested containers, no privileged pods, no gVisor. The tradeoff is that some OpenShell capabilities (per-binary network rules, hot policy updates, blueprint digest verification) don't have direct K8s equivalents.

## What This Is

NemoClaw is not just OpenClaw in a container. It is a five-layer security model built on top of NVIDIA's OpenShell runtime. Running OpenClaw with the NemoClaw container image but without those security layers is not NemoClaw.

NemoKube v2 translates each of NemoClaw's security layers into the closest Kubernetes-native equivalent:

| NemoClaw (OpenShell) | NemoKube v2 (K8s-native) | Parity |
|---|---|---|
| Landlock filesystem policies | Python wrapper calling Landlock syscalls with rules from `openclaw-sandbox.yaml` + custom seccomp profile allowing syscalls 444-446 | ~90% |
| seccomp syscall filtering | Custom profile deployed to nodes via DaemonSet, referenced by pod `seccompProfile: Localhost` | ~95% |
| Credential isolation (gateway outside sandbox) | Inference proxy pod holds API keys, sandbox has none. Proxy injects credentials into requests to NIM. | ~95% |
| Network namespace + per-host policies | K8s NetworkPolicy: sandbox can only reach proxy, proxy can only reach NIM, deny-default egress | ~85% |
| Process isolation (sandbox user, no caps) | `runAsNonRoot`, `runAsUser: 1000`, `capabilities: drop ALL`, PSA enforce=baseline | ~90% |

The one layer intentionally absent is OpenShell itself. OpenShell is a host-level container runtime; Kubernetes provides its own container orchestration. Replacing OpenShell with K8s primitives is the correct architectural choice for a GKE deployment.

**Remaining gap:** K8s NetworkPolicy operates at IP+port level. The official `openclaw-sandbox.yaml` specifies per-host, per-path rules (e.g., only `api.anthropic.com` on `POST /v1/messages`). For full FQDN parity, deploy Cilium and use CiliumNetworkPolicy with DNS-based rules.

## GKE Architecture (v2)

```
┌──────────────────────────────────────────────────────────────────┐
│  GKE Regional Cluster                                            │
│  PSA: enforce=baseline, warn=restricted                          │
│  Custom seccomp profile on all nodes (Landlock syscalls allowed)  │
│                                                                  │
│  ┌────────────────────────┐                                      │
│  │  Sandbox Pod            │                                      │
│  │  seccomp: Localhost     │                                      │
│  │  runAsNonRoot: true     │                                      │
│  │  capabilities: drop ALL │                                      │
│  │  NO NVIDIA_API_KEY      │                                      │
│  │                         │                                      │
│  │  landlock-wrapper.py    │     NetworkPolicy: deny-default      │
│  │    RO: /usr /lib /etc   │                                      │
│  │    RW: /tmp /sandbox/*  │                                      │
│  │    exec: openclaw gw    │                                      │
│  │  Dashboard :18789       │                                      │
│  └──────────┬──────────────┘                                      │
│             │ :8080 (no credentials)                              │
│  ┌──────────▼──────────────┐                                      │
│  │  Inference Proxy Pod    │                                      │
│  │  Holds NVIDIA_API_KEY   │                                      │
│  │  Injects Authorization  │                                      │
│  │  readOnlyRootFilesystem │                                      │
│  └──────────┬──────────────┘                                      │
│             │ :8000 (with credentials)                            │
│  ┌──────────▼──────────────┐     ┌────────────────────────────┐  │
│  │  NIM Inference (GPU)    │     │  Model Cache PVC           │  │
│  │  Your selected model    │     │  Survives pod restarts     │  │
│  │  OpenAI-compat API      │     │  and Spot preemption       │  │
│  └─────────────────────────┘     └────────────────────────────┘  │
│                                                                  │
│  ComputeClass ──▶ NAP auto-provisions GPU node pool              │
│  Pre-flight   ──▶ Scans zones for GPU availability               │
└──────────────────────────────────────────────────────────────────┘
```

The key difference from v1: the sandbox pod has **no API keys in its environment**. Inference traffic flows sandbox &rarr; proxy &rarr; NIM. The proxy injects the NVIDIA API key. This matches OpenShell's model where the gateway sits outside the sandbox and credentials never enter the container.

## Quick Start: GKE (Recommended)

```bash
export GCP_PROJECT="your-gcp-project-id"
export NVIDIA_API_KEY="nvapi-your-key-here"
chmod +x deploy.sh && ./deploy.sh
```

The script runs 17 steps: enables APIs, scans GPU zones, creates a regional cluster with NAP, installs the custom seccomp profile on all nodes, deploys the Landlock wrapper, deploys NIM on a GPU node via ComputeClass, deploys the inference proxy, launches the hardened sandbox, applies NetworkPolicies, and verifies all security layers.

**Estimated cost:** ~$330/mo on-demand, ~$190/mo with Spot VMs.

### Verify Security After Deployment

```bash
# Landlock active in sandbox
kubectl -n nemokube logs nemokube-0 -c nemokube-sandbox | grep landlock

# No API key in sandbox environment
kubectl -n nemokube exec nemokube-0 -- env | grep NVIDIA
# (should return nothing)

# API key IS in inference proxy
kubectl -n nemokube exec deploy/inference-proxy -- env | grep NVIDIA_API_KEY
# (should show the key)

# NetworkPolicy enforcement
kubectl -n nemokube get networkpolicy

# Seccomp profile on all nodes
kubectl -n kube-system get daemonset seccomp-installer

# PSA labels on namespace
kubectl get namespace nemokube --show-labels | grep pod-security
```

### Cleanup

```bash
./destroy-gke.sh
# or manually:
gcloud container clusters delete nemokube-cluster --region=$GKE_REGION --project=$GCP_PROJECT -q
```

## Quick Start: Cloud Run

> **Work in Progress:** The Cloud Run deployment does not yet implement the v2 security model. The NIM inference service deploys and runs correctly, but the gateway has unresolved issues with NemoClaw's config reload behavior causing WebSocket disconnects. Use the GKE deployment for a fully working setup.

```bash
export GCP_PROJECT="your-gcp-project-id"
export NVIDIA_API_KEY="nvapi-your-key-here"
chmod +x deploy-cloudrun.sh && ./deploy-cloudrun.sh
```

**Estimated cost:** ~$0/hr idle, ~$1.65/hr active.

### Cleanup

```bash
./destroy-cloudrun.sh
```

## Prerequisites

- **gcloud CLI** installed and authenticated
- **Docker** installed locally
- **NVIDIA API key** from [build.nvidia.com](https://build.nvidia.com) (must accept model license)
- GCP project with billing enabled
- **kubectl**
- **cluster-admin access** (required for seccomp profile DaemonSet and PSA namespace labels)
- GPU quota > 0 (GKE only -- Cloud Run auto-grants L4 quota)
- GKE nodes running Container-Optimized OS with kernel 5.15+ (default, required for Landlock)

## Model Selection

### GKE (L4 or A100)

```
  #  Model                        VRAM    GPU          Est. Cost
  ─  ─────────────────────────    ─────   ──────────   ──────────
  1  Nemotron Nano 30B (rec.)     24GB    A100 (40GB)  $3.67/hr
  2  Nemotron Super 49B           24GB    A100 (40GB)  $3.67/hr
  3  Nemotron Super 120B          40GB    A100 (40GB)  $3.67/hr
  4  Llama 3.1 8B (lightweight)   16GB    L4 (24GB)    $0.70/hr
```

### Cloud Run (L4 GPU only)

```
  #  Model                    CPU   Memory   GPU    Est. Cost
  ─  ────────────────────     ───   ──────   ────   ──────────
  1  Llama 3.1 8B (rec.)     8     32 GiB   L4     ~$1.65/hr
  2  Llama 3.1 8B (minimal)  4     16 GiB   L4     ~$0.90/hr
```

VRAM values are verified runtime requirements (not checkpoint sizes). The Nemotron Nano 30B needs ~23GB at runtime -- it does **not** fit on an L4 despite NVIDIA listing it as 8GB.

## Security Layers (GKE)

### Landlock Filesystem Isolation

The sandbox container runs `landlock-wrapper.py` before starting OpenClaw. The wrapper calls `landlock_create_ruleset`, `landlock_add_rule`, and `landlock_restrict_self` with rules matching the official `openclaw-sandbox.yaml`:

- **Read-only:** `/usr`, `/lib`, `/lib64`, `/proc`, `/dev/urandom`, `/app`, `/etc`, `/var/log`, `/sandbox`, `/sandbox/.openclaw`
- **Read-write:** `/tmp`, `/dev/null`, `/sandbox/.openclaw-data`, `/sandbox/.nemoclaw`

This requires a custom seccomp profile (deployed via DaemonSet to all nodes) that extends RuntimeDefault with the three Landlock syscalls (444, 445, 446). If Landlock is unavailable, the wrapper logs a warning and falls back to running without it.

### Credential Isolation (Inference Proxy)

The inference proxy (`manifests/07-inference-proxy.yaml`) is the credential isolation boundary. It holds the `NVIDIA_API_KEY` secret and injects it into `Authorization` headers on requests forwarded to NIM. The sandbox pod's environment contains **no API keys**. The OpenClaw config inside the sandbox points at the proxy with `apiKey: "proxy-injected"`.

### seccomp Profile

A DaemonSet in `kube-system` (`manifests/06-seccomp-installer.yaml`) writes a custom seccomp profile to `/var/lib/kubelet/seccomp/profiles/nemokube-sandbox.json` on every node. The profile uses `SCMP_ACT_ERRNO` as the default action with an explicit syscall allowlist based on Docker's RuntimeDefault, plus the Landlock syscalls.

### NetworkPolicy

Four policies enforce deny-default network isolation:

| Policy | Ingress | Egress |
|---|---|---|
| **NIM** | Only from inference proxy (:8000) | DNS + HTTPS (NGC model downloads) |
| **Inference Proxy** | Only from sandbox (:8080) | DNS + NIM (:8000) |
| **Sandbox** | Dashboard (:18789) from cluster | DNS + proxy (:8080) + HTTPS (:443) |
| **NIM Egress** | -- | DNS + HTTPS |

The sandbox **cannot** talk to NIM directly. All inference routes through the proxy.

### Pod Security

The sandbox pod runs with `runAsNonRoot: true`, `runAsUser: 1000`, `capabilities: drop ["ALL"]`, `allowPrivilegeEscalation: false`, and a custom seccomp profile. The namespace enforces PSA `baseline` and warns on `restricted`.

## GKE Features

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

## After Deployment

### GKE

```bash
kubectl -n nemokube port-forward svc/nemokube-dashboard 18789:80
# Open http://localhost:18789
```

### Cloud Run

Open the gateway URL printed at the end of deployment. Get the auth token from the logs:

```bash
gcloud run services logs read nemokube-gateway \
  --project=$GCP_PROJECT --region=$REGION --limit=100 | grep token
```

## File Layout

```
nemokube/
├── deploy.sh                         # GKE deployment (17 steps, security layers)
├── deploy-cloudrun.sh                # Cloud Run deployment [WIP]
├── destroy-gke.sh                    # Tear down GKE resources
├── destroy-cloudrun.sh               # Tear down Cloud Run resources
├── Dockerfile.gateway                # Cloud Run gateway image [WIP]
├── gateway-start.sh                  # Cloud Run gateway entrypoint [WIP]
├── scripts/
│   ├── landlock-wrapper.py           # Landlock filesystem isolation wrapper
│   ├── 01-create-gke-cluster.sh      # Standalone cluster creation
│   └── 02-build-and-push-image.sh
├── manifests/
│   ├── 00-namespace.yaml             # Namespace with PSA labels
│   ├── 01-secrets.yaml
│   ├── 02-configmap.yaml
│   ├── 03-nim-deployment.yaml        # NIM inference (GPU)
│   ├── 04-nemoclaw-deployment.yaml   # Hardened sandbox (Landlock + seccomp)
│   ├── 05-networkpolicy.yaml         # Deny-default 3-tier isolation
│   ├── 06-seccomp-installer.yaml     # DaemonSet: custom seccomp on all nodes
│   └── 07-inference-proxy.yaml       # Credential isolation proxy
├── docs/
│   ├── NemoKube_v2_PRD.docx          # v2 architecture PRD
│   ├── NemoClaw_on_CloudRun_Guide.docx
│   ├── NemoClaw_on_GKE_Guide.docx
│   ├── GKE_GPU_Friction_Log_v2.docx
│   └── GKE_GPU_Friction_Log.docx
└── README.md
```

## Troubleshooting

**Landlock not active** -- Check that the seccomp DaemonSet is running on all nodes (`kubectl -n kube-system get ds seccomp-installer`) and that the pod references the Localhost seccomp profile. COS kernel must be 5.15+.

**Inference proxy not ready** -- The proxy starts immediately but NIM takes 5-15 minutes to load models. The proxy returns 502 until NIM is healthy. Check NIM logs: `kubectl -n nemokube logs deploy/nim-inference`.

**"No zones in REGION have GPU_TYPE"** -- Try a different region: `GKE_REGION=us-west1 ./deploy.sh`

**ImagePullBackOff on NIM** -- Accept the model license at [build.nvidia.com](https://build.nvidia.com).

**CUDA out of memory** -- The model doesn't fit. Nemotron Nano 30B needs A100 (40GB), not L4 (24GB).

**GPU quota exceeded** -- Request increase at IAM & Admin > Quotas > "GPUs (all regions)". Cloud Run auto-grants L4 quota.

**Context overflow** -- NIM's default 16K context is too small for NemoClaw. The deploy script sets `NIM_MAX_MODEL_LEN=16384`.

**Model 404** -- OpenClaw strips the provider prefix from model names. The deploy script sets `NIM_SERVED_MODEL_NAME` to work around this.

**PSA rejection** -- If pods fail to create with "violates PodSecurity," check that the namespace has `pod-security.kubernetes.io/enforce: baseline`. The deploy script sets this automatically.

## How NemoKube Handles NemoClaw Alpha Quirks

NemoClaw is alpha software. The deploy script handles several quirks automatically:

| Quirk | What Happens | How NemoKube Handles It |
|---|---|---|
| `nemoclaw-start` backgrounds the gateway then exits | Container would stop | Init container runs `nemoclaw-start` for plugin bootstrapping only, then `landlock-wrapper.py` execs `openclaw gateway run` as PID 1 |
| Default config hardcodes `nemotron-3-super-120b` | Wrong model for your GPU | Init container writes `openclaw.json` pointing at the inference proxy with your selected model |
| OpenClaw strips provider prefix from model names | NIM returns 404 | `NIM_SERVED_MODEL_NAME` set to the short model name |
| Gateway binds 127.0.0.1 only | K8s tcpSocket probes fail via pod IP | exec-based health probes: `exec 3<>/dev/tcp/127.0.0.1/18789` |

## Notes

- **This project is experimental and a work in progress.** It is not supported by, endorsed by, or affiliated with Google or NVIDIA. Use at your own risk.
- NemoClaw is alpha software (GTC 2026). APIs are evolving, and NemoKube's workarounds may break as NemoClaw matures. If NVIDIA ships an official Kubernetes deployment method, prefer that over this project.
- The Landlock and seccomp implementation has not been independently security-audited. Do not rely on it for production workloads without your own review.
- VRAM sizes are runtime measurements, not checkpoint sizes.
- Costs are estimates for `us-central1`. Pricing varies by region.
- For production, replace K8s Secrets with Workload Identity + Secret Manager.
- For FQDN-based network filtering, deploy Cilium and use CiliumNetworkPolicy.
