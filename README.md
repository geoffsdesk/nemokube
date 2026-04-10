# NemoKube

> **This project is experimental, a work in progress, and not supported by Google or NVIDIA.** It exists to explore what it takes to run NemoClaw's security model on GKE. Expect rough edges, breaking changes, and incomplete features. Written against NemoClaw alpha (GTC 2026).

Run the real NemoClaw process chain on GKE. One-command deployment of [NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw) on Google Cloud with NIM inference, using `nemoclaw-start` as the actual container entrypoint for native security hardening, with Kubernetes layers for defense-in-depth.

Two deployment options: **GKE** (recommended, full security stack) or **Cloud Run** (WIP, serverless).

## Other Approaches to NemoClaw on Kubernetes

NemoKube is one of several ways to run NemoClaw in a Kubernetes environment. Before choosing this approach, you should be aware of the alternatives:

**NVIDIA's official method (nested containers):** The [NemoClaw repository](https://github.com/NVIDIA/NemoClaw) runs OpenShell inside a Kubernetes pod, effectively nesting container management within K8s. This preserves the full OpenShell runtime (including its native Landlock, seccomp, and credential management) at the cost of requiring privileged pods or sysbox for nested container support. If your cluster allows privileged workloads, this is the most faithful way to run NemoClaw on K8s.

**NemoKube's approach (nemoclaw-start + K8s defense-in-depth):** This repo runs `nemoclaw-start` as the real container entrypoint (PID 1), so the full NemoClaw hardening sequence executes natively: ulimit, PATH locking, config integrity (SHA256 + chattr +i), capability dropping (capsh), and privilege separation (gosu to unprivileged gateway user). K8s layers add defense-in-depth: custom seccomp profile, credential isolation via an inference proxy pod, deny-default NetworkPolicy, and PSA baseline enforcement. The tradeoff is that OpenShell's host-side L7 proxy is replaced by a K8s inference proxy pod, and some OpenShell capabilities (per-binary network rules, hot policy updates, blueprint digest verification) don't have direct K8s equivalents.

## What This Is

NemoClaw is not just OpenClaw in a container. It is a five-layer security model built on top of NVIDIA's OpenShell runtime. Running OpenClaw with the NemoClaw container image but without those security layers is not NemoClaw.

NemoKube v3 runs the actual NemoClaw process chain (`nemoclaw-start` → `gosu gateway` → `openclaw gateway run`) and adds K8s-native layers for defense-in-depth:

| Layer | NemoClaw (OpenShell) | NemoKube v3 | Parity |
|---|---|---|---|
| Process chain | `nemoclaw-start` → `gosu` → `openclaw gateway run` | Same — nemoclaw-start runs as PID 1, drops to gateway user via gosu | ~100% |
| Privilege separation | Root → capability drop (capsh) → gateway user (gosu) | Same — container starts as root, nemoclaw-start drops privs natively | ~100% |
| Config integrity | SHA256 hash + `chattr +i` (immutable) | Same — nemoclaw-start performs these natively | ~100% |
| seccomp filtering | OpenShell-managed profile | Custom profile via DaemonSet, extends RuntimeDefault with Landlock + capsh + gosu syscalls | ~95% |
| Credential isolation | OpenShell L7 proxy on host, gateway outside sandbox | Inference proxy pod holds API keys, sandbox has none. Proxy injects credentials into NIM requests. | ~90% |
| Network isolation | Per-host, per-path FQDN rules | K8s NetworkPolicy: sandbox → proxy → NIM, deny-default egress. IP+port level (not FQDN). | ~85% |
| Filesystem isolation | Landlock via OpenShell | Landlock wrapper available as supplementary layer (seccomp profile allows syscalls 444-446) | ~85% |

**What changed from v2:** v2 killed `nemoclaw-start` after extracting side effects and ran `openclaw gateway run` directly via a Landlock wrapper. This missed the core of NemoClaw — the hardening sequence that `nemoclaw-start` performs as PID 1. v3 runs `nemoclaw-start` for real.

**Remaining gap:** K8s NetworkPolicy operates at IP+port level. The official `openclaw-sandbox.yaml` specifies per-host, per-path rules (e.g., only `api.anthropic.com` on `POST /v1/messages`). For full FQDN parity, deploy Cilium and use CiliumNetworkPolicy with DNS-based rules.

## GKE Architecture (v3)

```
┌──────────────────────────────────────────────────────────────────┐
│  GKE Regional Cluster                                            │
│  PSA: enforce=baseline, warn=restricted                          │
│  Custom seccomp profile on all nodes (Landlock+capsh+gosu)       │
│                                                                  │
│  ┌────────────────────────────┐                                  │
│  │  Sandbox Pod (StatefulSet)  │                                  │
│  │  seccomp: Localhost         │                                  │
│  │  NO NVIDIA_API_KEY          │                                  │
│  │                             │                                  │
│  │  nemoclaw-start (PID 1)     │                                  │
│  │    ├─ ulimit restrictions   │    NetworkPolicy: deny-default   │
│  │    ├─ PATH locking          │                                  │
│  │    ├─ SHA256 config check   │                                  │
│  │    ├─ chattr +i .openclaw   │                                  │
│  │    ├─ capsh (drop caps)     │                                  │
│  │    └─ gosu gateway ─────────┤                                  │
│  │       └─ openclaw gw run    │                                  │
│  │          Dashboard :18789   │                                  │
│  └──────────┬──────────────────┘                                  │
│             │ :8080 (no credentials)                              │
│  ┌──────────▼──────────────────┐                                  │
│  │  Inference Proxy Pod        │                                  │
│  │  Holds NVIDIA_API_KEY       │                                  │
│  │  Injects Authorization      │                                  │
│  │  readOnlyRootFilesystem     │                                  │
│  └──────────┬──────────────────┘                                  │
│             │ :8000 (with credentials)                            │
│  ┌──────────▼──────────────────┐     ┌────────────────────────┐  │
│  │  NIM Inference (GPU)        │     │  Model Cache PVC       │  │
│  │  Your selected model        │     │  Survives pod restarts │  │
│  │  OpenAI-compat API          │     │  and Spot preemption   │  │
│  └─────────────────────────────┘     └────────────────────────┘  │
│                                                                  │
│  ComputeClass ──▶ NAP auto-provisions GPU node pool              │
│  Pre-flight   ──▶ Scans zones for GPU availability               │
└──────────────────────────────────────────────────────────────────┘
```

The key difference from v2: the sandbox pod runs `nemoclaw-start` as PID 1 with the full hardening sequence. The container starts as root (required for capsh, chattr, gosu), then `nemoclaw-start` drops to unprivileged `gateway` user via gosu. The inference proxy handles credential isolation, replacing OpenShell's host-side L7 proxy.

## Quick Start: GKE (Recommended)

```bash
export GCP_PROJECT="your-gcp-project-id"
export NVIDIA_API_KEY="nvapi-your-key-here"
chmod +x deploy.sh && ./deploy.sh
```

The script runs 17 steps: enables APIs, scans GPU zones, creates a regional cluster with NAP, installs the custom seccomp profile on all nodes, deploys NIM on a GPU node via ComputeClass, deploys the inference proxy, launches the sandbox with `nemoclaw-start` as entrypoint, applies NetworkPolicies, and verifies the process chain.

**Estimated cost:** ~$330/mo on-demand, ~$190/mo with Spot VMs.

### Verify Security After Deployment

```bash
# Check nemoclaw-start hardening completed
kubectl -n nemokube logs nemokube-0 -c nemokube-sandbox | grep nemoclaw

# Verify process chain: nemoclaw-start → gosu → openclaw gateway
kubectl -n nemokube exec nemokube-0 -- ps auxf

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

> **Work in Progress:** The Cloud Run deployment does not yet implement the v3 security model. The NIM inference service deploys and runs correctly, but the gateway has unresolved issues with NemoClaw's config reload behavior causing WebSocket disconnects. Use the GKE deployment for a fully working setup.

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

### nemoclaw-start Native Hardening

The sandbox container runs `nemoclaw-start` as PID 1 — the same entrypoint NVIDIA uses in their container runtime. This performs the full NemoClaw hardening sequence:

1. **ulimit restrictions** — Limits open files, processes, and core dumps
2. **PATH locking** — Exports PATH and marks it readonly to prevent PATH hijacking
3. **Config SHA256 integrity** — Computes SHA256 of `openclaw.json` and verifies it hasn't been tampered with
4. **Immutable config** — Runs `chattr +i` on `.openclaw/` to prevent any modification after bootstrap
5. **Capability dropping** — Uses `capsh --drop=...` to remove dangerous Linux capabilities
6. **Privilege separation** — Calls `gosu gateway openclaw gateway run` to drop from root to unprivileged `gateway` user

After step 6, the OpenClaw gateway runs as the unprivileged `gateway` user with minimal capabilities. The root privilege is only needed during the bootstrap phase (steps 1-6).

### Credential Isolation (Inference Proxy)

The inference proxy (`manifests/07-inference-proxy.yaml`) is the credential isolation boundary. It holds the `NVIDIA_API_KEY` secret and injects it into `Authorization` headers on requests forwarded to NIM. The sandbox pod's environment contains **no API keys**. The OpenClaw config inside the sandbox points at the proxy with `apiKey: "proxy-injected"`.

This replaces OpenShell's host-side L7 proxy, which on bare metal sits outside the sandbox and manages credential injection. On K8s, the inference proxy pod fills the same role.

### Custom seccomp Profile

A DaemonSet in `kube-system` (`manifests/06-seccomp-installer.yaml`) writes a custom seccomp profile to `/var/lib/kubelet/seccomp/profiles/nemokube-sandbox.json` on every node. The profile uses `SCMP_ACT_ERRNO` as the default action with an explicit syscall allowlist based on Docker's RuntimeDefault, plus:

- Landlock syscalls (444, 445, 446) for filesystem isolation
- `chroot` for capsh capability dropping
- `ioctl` for chattr +i immutable flag
- `setuid`/`setgid` for gosu privilege separation

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

The sandbox pod starts as root (required for nemoclaw-start's privilege separation) with specific capabilities: SETUID, SETGID, SETPCAP, CHOWN, FOWNER, DAC_OVERRIDE, LINUX_IMMUTABLE. After nemoclaw-start completes its hardening sequence, the gateway process runs as unprivileged `gateway` user with most capabilities dropped by capsh. The namespace enforces PSA `baseline` and warns on `restricted`.

### Landlock Filesystem Isolation (Supplementary)

The `scripts/landlock-wrapper.py` script is available as a supplementary filesystem isolation layer. It calls Landlock syscalls with rules matching `openclaw-sandbox.yaml` (read-only: `/usr`, `/lib`, `/etc`, etc.; read-write: `/tmp`, `/sandbox/.openclaw-data`). This can be used in addition to nemoclaw-start's native hardening for defense-in-depth.

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
├── deploy.sh                         # GKE deployment (17 steps, nemoclaw-start + K8s layers)
├── deploy-cloudrun.sh                # Cloud Run deployment [WIP]
├── destroy-gke.sh                    # Tear down GKE resources
├── destroy-cloudrun.sh               # Tear down Cloud Run resources
├── Dockerfile.gateway                # Cloud Run gateway image [WIP]
├── gateway-start.sh                  # Cloud Run gateway entrypoint [WIP]
├── scripts/
│   ├── landlock-wrapper.py           # Supplementary Landlock filesystem isolation
│   ├── 01-create-gke-cluster.sh      # Standalone cluster creation
│   └── 02-build-and-push-image.sh
├── manifests/
│   ├── 00-namespace.yaml             # Namespace with PSA labels
│   ├── 01-secrets.yaml
│   ├── 02-configmap.yaml
│   ├── 03-nim-deployment.yaml        # NIM inference (GPU)
│   ├── 04-nemoclaw-deployment.yaml   # Sandbox: nemoclaw-start as PID 1
│   ├── 05-networkpolicy.yaml         # Deny-default 3-tier isolation
│   ├── 06-seccomp-installer.yaml     # DaemonSet: seccomp with Landlock+capsh+gosu
│   └── 07-inference-proxy.yaml       # Credential isolation proxy
├── docs/
│   ├── NemoKube_v3_PRD.docx          # v3 architecture PRD
│   ├── NemoKube_v2_PRD.docx          # v2 architecture PRD
│   ├── NemoClaw_on_CloudRun_Guide.docx
│   ├── NemoClaw_on_GKE_Guide.docx
│   ├── GKE_GPU_Friction_Log_v2.docx
│   └── GKE_GPU_Friction_Log.docx
└── README.md
```

## Troubleshooting

**nemoclaw-start fails with permission denied** -- The container must start as root (runAsUser: 0) for the privilege separation sequence. Check that the namespace PSA is `baseline` (not `restricted`) and `allowPrivilegeEscalation: true` is set.

**capsh/chattr/gosu fails** -- The custom seccomp profile may be missing from the node. Verify: `kubectl -n kube-system get ds seccomp-installer`. The profile must include `chroot`, `setuid`, `setgid`, and `ioctl` syscalls.

**Process tree doesn't show gosu/gateway** -- nemoclaw-start may have failed silently. Check init logs: `kubectl -n nemokube logs nemokube-0 -c write-config` and main container logs: `kubectl -n nemokube logs nemokube-0 -c nemokube-sandbox`.

**Inference proxy not ready** -- The proxy starts immediately but NIM takes 5-15 minutes to load models. The proxy returns 502 until NIM is healthy. Check NIM logs: `kubectl -n nemokube logs deploy/nim-inference`.

**"No zones in REGION have GPU_TYPE"** -- Try a different region: `GKE_REGION=us-west1 ./deploy.sh`

**ImagePullBackOff on NIM** -- Accept the model license at [build.nvidia.com](https://build.nvidia.com).

**CUDA out of memory** -- The model doesn't fit. Nemotron Nano 30B needs A100 (40GB), not L4 (24GB).

**GPU quota exceeded** -- Request increase at IAM & Admin > Quotas > "GPUs (all regions)". Cloud Run auto-grants L4 quota.

**PSA rejection** -- If pods fail to create with "violates PodSecurity," check that the namespace has `pod-security.kubernetes.io/enforce: baseline`. The deploy script sets this automatically.

## How NemoKube Handles NemoClaw Alpha Quirks

NemoClaw is alpha software. The deploy script handles several quirks automatically:

| Quirk | What Happens | How NemoKube Handles It |
|---|---|---|
| No OpenShell host-side L7 proxy on K8s | Sandbox can't route inference through OpenShell's proxy | Inference proxy pod holds API key, injects credentials. Init container writes `openclaw.json` pointing at proxy. |
| Default config hardcodes `nemotron-3-super-120b` | Wrong model for your GPU | Init container writes `openclaw.json` with your selected model |
| OpenClaw strips provider prefix from model names | NIM returns 404 | `NIM_SERVED_MODEL_NAME` set to the short model name |
| Gateway binds 127.0.0.1 only | K8s tcpSocket probes fail via pod IP | exec-based health probes: `exec 3<>/dev/tcp/127.0.0.1/18789` |
| nemoclaw-start needs root for hardening | Conflicts with K8s restricted PSA | PSA set to baseline, container starts as root, nemoclaw-start drops to gateway user |

## Version History

- **v3** — Run the real `nemoclaw-start` process chain as PID 1. Native privilege separation (capsh + gosu), config integrity (SHA256 + chattr +i), K8s layers for defense-in-depth.
- **v2** — K8s-native translation of NemoClaw security layers. Landlock wrapper, credential isolation proxy, custom seccomp. Did not run nemoclaw-start or the OpenShell gateway.
- **v1** — Bare OpenClaw with NIM. No NemoClaw security layers.

## Notes

- **This project is experimental and a work in progress.** It is not supported by, endorsed by, or affiliated with Google or NVIDIA. Use at your own risk.
- NemoClaw is alpha software (GTC 2026). APIs are evolving, and NemoKube's workarounds may break as NemoClaw matures. If NVIDIA ships an official Kubernetes deployment method, prefer that over this project.
- The security implementation has not been independently audited. Do not rely on it for production workloads without your own review.
- VRAM sizes are runtime measurements, not checkpoint sizes.
- Costs are estimates for `us-central1`. Pricing varies by region.
- For production, replace K8s Secrets with Workload Identity + Secret Manager.
- For FQDN-based network filtering, deploy Cilium and use CiliumNetworkPolicy.
