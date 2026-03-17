#!/usr/bin/env bash
# NemoKube — Build sandbox image and push to Artifact Registry.
set -euo pipefail

PROJECT="${GCP_PROJECT:?Set GCP_PROJECT to your Google Cloud project ID}"
REGION="${GKE_REGION:-us-central1}"
REPO_NAME="nemokube-images"
IMAGE_NAME="nemokube-sandbox"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO_NAME}/${IMAGE_NAME}:${IMAGE_TAG}"

echo "==> Creating Artifact Registry repository (if needed)"
gcloud artifacts repositories create "${REPO_NAME}" \
  --project="${PROJECT}" \
  --repository-format=docker \
  --location="${REGION}" \
  --description="NemoKube container images" \
  2>/dev/null || echo "    Repository already exists."

echo "==> Configuring Docker auth for Artifact Registry"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

echo "==> Cloning NemoClaw repo"
TMPDIR=$(mktemp -d)
git clone https://github.com/NVIDIA/NemoClaw.git "${TMPDIR}/NemoClaw"
cd "${TMPDIR}/NemoClaw"

echo "==> Building NemoClaw sandbox image"
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" .

echo "==> Tagging and pushing to ${FULL_IMAGE}"
docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${FULL_IMAGE}"
docker push "${FULL_IMAGE}"

echo ""
echo "==> Image pushed: ${FULL_IMAGE}"
echo "    Update manifests/04-nemoclaw-deployment.yaml image fields to:"
echo "    ${FULL_IMAGE}"
echo ""

# Clean up
rm -rf "${TMPDIR}"
