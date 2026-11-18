#!/usr/bin/env bash
# =============================================================================
# deploy-s4.sh
#
# Deploy in-repo S4 (S3-compatible object storage) and create the Loki bucket.
# Reads S4_* values from configure-overlays.sh HEADER (sourced), or uses defaults.
#
# Prerequisites:
#   - Edit S4_* (and related) values in configure-overlays.sh HEADER
#   - Run ./configure-overlays.sh so s4/overlays/<S4_OVERLAY> patches are current
#   - oc logged in; kubeconfig at KUBECONFIG_PATH (default $HOME/ocpkubeconfig)
#
# Usage:
#   ./deploy-s4.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

# Load HEADER assignments from configure-overlays.sh without executing main.
# shellcheck disable=SC1091
eval "$(
  awk '
    /^# HEADER/ { keep=1; next }
    /^# =+.*Runtime paths/ { exit }
    keep && /^[A-Za-z_][A-Za-z0-9_]*=/ { print }
  ' "${REPO_ROOT}/configure-overlays.sh"
)"

S4_NAMESPACE="${S4_NAMESPACE:-s4}"
S4_OVERLAY="${S4_OVERLAY:-lab}"
S4_BUCKET_NAME="${S4_BUCKET_NAME:-${LOKI_S3_BUCKET:-loggingstack}}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/ocpkubeconfig}"
S4_OVERLAY_DIR="${REPO_ROOT}/s4/overlays/${S4_OVERLAY}"

OC=(oc)
if [[ -f "${KUBECONFIG_PATH}" ]]; then
  OC=(oc --kubeconfig "${KUBECONFIG_PATH}")
fi

if [[ ! -d "${S4_OVERLAY_DIR}" ]]; then
  echo "ERROR: S4 overlay missing: ${S4_OVERLAY_DIR}" >&2
  echo "       Set S4_OVERLAY in configure-overlays.sh HEADER and run ./configure-overlays.sh" >&2
  exit 1
fi

for bin in oc curl python3; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "ERROR: ${bin} is required" >&2
    exit 1
  fi
done

json_login() {
  UI_USER="$1" UI_PASS="$2" python3 - <<'PY'
import json, os
print(json.dumps({"username": os.environ["UI_USER"], "password": os.environ["UI_PASS"]}))
PY
}

json_bucket() {
  S4_BUCKET_NAME="$1" python3 - <<'PY'
import json, os
print(json.dumps({"bucketName": os.environ["S4_BUCKET_NAME"]}))
PY
}

echo "=== Deploy S4 ==="
echo "  S4_NAMESPACE=${S4_NAMESPACE}"
echo "  S4_OVERLAY=${S4_OVERLAY}"
echo "  S4_BUCKET_NAME=${S4_BUCKET_NAME}"
echo "  overlay=${S4_OVERLAY_DIR}"

echo "Ensuring namespace ${S4_NAMESPACE} ..."
"${OC[@]}" create namespace "${S4_NAMESPACE}" --dry-run=client -o yaml | "${OC[@]}" apply -f -

echo "Applying s4/overlays/${S4_OVERLAY} ..."
"${OC[@]}" apply -n "${S4_NAMESPACE}" -k "${S4_OVERLAY_DIR}"

echo "Restarting deployment/s4 to pick up Secret changes ..."
"${OC[@]}" rollout restart deployment/s4 -n "${S4_NAMESPACE}"
"${OC[@]}" rollout status deployment/s4 -n "${S4_NAMESPACE}" --timeout=600s

echo "Reading UI credentials from Secret s4-credentials ..."
UI_USER="$("${OC[@]}" get secret s4-credentials -n "${S4_NAMESPACE}" -o jsonpath='{.data.UI_USERNAME}' | base64 -d)"
UI_PASS="$("${OC[@]}" get secret s4-credentials -n "${S4_NAMESPACE}" -o jsonpath='{.data.UI_PASSWORD}' | base64 -d)"

echo "Waiting for UI Route s4 ..."
UI_HOST=""
for _ in $(seq 1 30); do
  UI_HOST="$("${OC[@]}" get route s4 -n "${S4_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${UI_HOST}" ]]; then
    break
  fi
  sleep 5
done
if [[ -z "${UI_HOST}" ]]; then
  echo "ERROR: Route s4 has no host yet" >&2
  exit 1
fi

API_BASE="https://${UI_HOST}/api"
echo "  UI host: ${UI_HOST}"
echo "  API base: ${API_BASE}"

echo "Waiting for S4 API /auth/info ..."
for _ in $(seq 1 30); do
  if curl -skf "${API_BASE}/auth/info" >/tmp/s4-auth-info.json 2>/dev/null; then
    break
  fi
  sleep 10
done
if [[ ! -s /tmp/s4-auth-info.json ]]; then
  echo "ERROR: S4 API not ready at ${API_BASE}/auth/info" >&2
  exit 1
fi

AUTH_REQUIRED="$(python3 -c 'import json; print(json.load(open("/tmp/s4-auth-info.json")).get("authRequired", False))')"
AUTH_HEADER=()
if [[ "${AUTH_REQUIRED}" == "True" ]]; then
  echo "Logging into S4 API ..."
  curl -skf -X POST "${API_BASE}/auth/login" \
    -H 'Content-Type: application/json' \
    -d "$(json_login "${UI_USER}" "${UI_PASS}")" \
    >/tmp/s4-login.json
  TOKEN="$(python3 -c 'import json; print(json.load(open("/tmp/s4-login.json"))["token"])')"
  AUTH_HEADER=(-H "Authorization: Bearer ${TOKEN}")
fi

echo "Creating bucket ${S4_BUCKET_NAME} (409 = already exists) ..."
HTTP_CODE="$(
  curl -sk -o /tmp/s4-bucket.json -w '%{http_code}' -X POST "${API_BASE}/buckets" \
    -H 'Content-Type: application/json' \
    "${AUTH_HEADER[@]}" \
    -d "$(json_bucket "${S4_BUCKET_NAME}")"
)"
case "${HTTP_CODE}" in
  200) echo "Bucket ${S4_BUCKET_NAME} created successfully" ;;
  409) echo "Bucket ${S4_BUCKET_NAME} already exists" ;;
  *)
    echo "ERROR: bucket create failed (HTTP ${HTTP_CODE})" >&2
    cat /tmp/s4-bucket.json >&2 || true
    exit 1
    ;;
esac

S3_HOST="$("${OC[@]}" get route s4-api -n "${S4_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
echo
echo "Done."
echo "  UI:       https://${UI_HOST}"
echo "  S3 API:   https://${S3_HOST:-<set S4_API_HOST / route host>}"
echo "  Bucket:   ${S4_BUCKET_NAME}"
echo
echo "Next: set S4_DEPLOYED_ON_CLUSTER=true in configure-overlays.sh HEADER,"
echo "      run ./configure-overlays.sh to refresh Loki TLS CA, then deploy logging."
