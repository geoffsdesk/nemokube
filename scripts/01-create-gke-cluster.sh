#!/usr/bin/env bash
# NemoKube — GKE Cluster Provisioning
# Creates a GKE cluster with a CPU system pool + an L4 GPU node pool.
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
PROJECT="${GCP_PROJECT:?Set GCP_PROJECT to your Google Cloud project ID}"
REGION="${GKE_REGION:-us-central1}"
ZONE="${GKE_ZONE:-us-central1-a}"
CLUSTER_NAME="${GKE_CLUSTER_NAME:-nemokube-cluster}"
GPU_POOL_NAME="gpu-l4-pool"
GPU_TYPE="nvidia-l4"
GPU_COUNT=1                          # GPUs per node
GPU_NODES_MIN=1
GPU_NODES_MAX=3
GPU_MACHINE_TYPE="g2-standard-8"     # 8 vCPU, 32 GB RAM, 1x L4 GPU
SYSTEM_MACHINE_TYPE="e2-standard-4"  # 4 vCPU, 16 GB for system workloads
K8S_VERSION="1.30"                   # GKE rapid channel

echo "==> Creating GKE cluster: ${CLUSTER_NAME} in ${REGION}"

# Create the cluster with a small system node pool (no GPUs)
gcloud container clusters create "${CLUSTER_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --release-channel=rapid \
  --cluster-version="${K8S_VERSION}" \
  --machine-type="${SYSTEM_MACHINE_TYPE}" \
  --num-nodes=2 \
  --enable-autoscaling --min-nodes=1 --max-nodes=3 \
  --workload-pool="${PROJECT}.svc.id.goog" \
  --enable-ip-alias \
  --logging=SYSTEM,WORKLOAD \
  --monitoring=SYSTEM \
  --addons=GcsFuseCsiDriver

echo "==> Adding L4 GPU node pool: ${GPU_POOL_NAME}"

# Add a GPU node pool with L4 accelerators
# --node-labels tells the GPU Operator NOT to install the default device plugin
gcloud container node-pools create "${GPU_POOL_NAME}" \
  --project="${PROJECT}" \
  --cluster="${CLUSTER_NAME}" \
  --zone="${ZONE}" \
  --machine-type="${GPU_MACHINE_TYPE}" \
  --accelerator="type=${GPU_TYPE},count=${GPU_COUNT},gpu-driver-version=latest" \
  --num-nodes="${GPU_NODES_MIN}" \
  --enable-autoscaling \
  --min-nodes="${GPU_NODES_MIN}" \
  --max-nodes="${GPU_NODES_MAX}" \
  --node-taints="nvidia.com/gpu=present:NoSchedule" \
  --node-labels="gpu-type=nvidia-l4" \
  --sandbox type=gvisor

echo "==> Adding sandboxed CPU pool for NemoClaw agent"

# Separate CPU pool with gVisor for the NemoClaw sandbox (the default pool
# doesn't support gVisor — --sandbox is a node-pool-level flag).
gcloud container node-pools create "sandbox-cpu-pool" \
  --project="${PROJECT}" \
  --cluster="${CLUSTER_NAME}" \
  --zone="${ZONE}" \
  --machine-type="${SYSTEM_MACHINE_TYPE}" \
  --num-nodes=1 \
  --enable-autoscaling \
  --min-nodes=0 \
  --max-nodes=2 \
  --sandbox type=gvisor

echo "==> Fetching cluster credentials"
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}"

echo "==> Verifying GPU nodes"
kubectl get nodes -l gpu-type=nvidia-l4 -o wide

echo ""
echo "==> Cluster ${CLUSTER_NAME} is ready."
echo "    Next: kubectl apply -f manifests/"
