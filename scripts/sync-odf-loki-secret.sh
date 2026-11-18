#!/usr/bin/env bash
# =============================================================================
# sync-odf-loki-secret.sh
#
# Manual helper for Kustomize-only (non-Argo) ODF deploys.
# Reads credentials from an ObjectBucketClaim Secret/ConfigMap and creates the
# LokiStack-compatible Secret (logging-loki-s3 by default).
#
# Usage:
#   ./scripts/sync-odf-loki-secret.sh
#   OBC_NAME=logging-loki-obc NAMESPACE=openshift-logging ./scripts/sync-odf-loki-secret.sh
# =============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-openshift-logging}"
OBC_NAME="${OBC_NAME:-logging-loki-obc}"
LOKI_SECRET_NAME="${LOKI_SECRET_NAME:-logging-loki-s3}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/ocpkubeconfig}"

OC=(oc)
if [[ -f "${KUBECONFIG_PATH}" ]]; then
  OC=(oc --kubeconfig "${KUBECONFIG_PATH}")
fi

echo "Waiting for ObjectBucketClaim ${OBC_NAME} in ${NAMESPACE} ..."
for _ in $(seq 1 60); do
  phase="$("${OC[@]}" get objectbucketclaim "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${phase}" == "Bound" ]]; then
    break
  fi
  sleep 5
done

phase="$("${OC[@]}" get objectbucketclaim "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')"
if [[ "${phase}" != "Bound" ]]; then
  echo "ERROR: ObjectBucketClaim ${OBC_NAME} not Bound (phase=${phase})" >&2
  exit 1
fi

ACCESS_KEY="$("${OC[@]}" get secret "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)"
SECRET_KEY="$("${OC[@]}" get secret "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)"
BUCKET="$("${OC[@]}" get configmap "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.BUCKET_NAME}')"
HOST="$("${OC[@]}" get configmap "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.BUCKET_HOST}')"
PORT="$("${OC[@]}" get configmap "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.BUCKET_PORT}')"
REGION="$("${OC[@]}" get configmap "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.BUCKET_REGION}')"
REGION="${REGION:-us-east-1}"

if [[ -z "${PORT}" || "${PORT}" == "443" ]]; then
  ENDPOINT="https://${HOST}"
else
  ENDPOINT="https://${HOST}:${PORT}"
fi

echo "Creating/updating ${LOKI_SECRET_NAME} (bucket=${BUCKET}, endpoint=${ENDPOINT})"
"${OC[@]}" create secret generic "${LOKI_SECRET_NAME}" \
  -n "${NAMESPACE}" \
  --from-literal=access_key_id="${ACCESS_KEY}" \
  --from-literal=access_key_secret="${SECRET_KEY}" \
  --from-literal=bucketnames="${BUCKET}" \
  --from-literal=endpoint="${ENDPOINT}" \
  --from-literal=region="${REGION}" \
  --from-literal=forcepathstyle="true" \
  --dry-run=client -o yaml | "${OC[@]}" apply -f -

echo "Done."
