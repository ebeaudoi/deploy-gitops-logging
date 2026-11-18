#!/usr/bin/env bash
# =============================================================================
# configure-overlays.sh
#
# Idempotent overlay updater for OpenShift Logging (LokiStack + GitOps).
#
# Usage:
#   1) Edit the HEADER section below (no CLI parameters).
#   2) Run:  ./configure-overlays.sh
#
# Typical S4 lab flow:
#   1) HEADER: STORAGE_BACKEND=s4, OVERLAY, S4_*, LOKI_STORAGE_CLASS, GIT_REPO_URL
#   2) ./configure-overlays.sh && ./deploy-s4.sh
#   3) HEADER: S4_DEPLOYED_ON_CLUSTER=true → ./configure-overlays.sh
#   4) Deploy logging (oc apply -k … or GitOps)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
LOGGING_ARGOCD_DIR="${REPO_ROOT}/logging/argoCD"
APP_OF_APPS_DIR="${REPO_ROOT}/gitops/app-of-apps"
GITOPS_DIR="${REPO_ROOT}/gitops"
APPSET_FILE="${GITOPS_DIR}/applicationset/logging-applicationset.yaml"

# =============================================================================
# HEADER — minimum required settings (edit these)
# =============================================================================

# Overlay name for logging (and S4 when STORAGE_BACKEND=s4).
# Missing dirs are seeded from overlays/s3, overlays/odf, or s4/overlays/lab.
OVERLAY="lab"

# Object storage: s4 | s3 | odf
#   s4  = in-repo S4 (lab)
#   s3  = external S3-compatible endpoint
#   odf = OpenShift Data Foundation / NooBaa ObjectBucketClaim
STORAGE_BACKEND="s4"

# Block StorageClass for Loki PVCs (must exist on the cluster)
LOKI_STORAGE_CLASS="thin-csi"

# --- Operator Subscription channels (redhat-operators) ---
# Discover defaults:
#   oc get packagemanifest -n openshift-marketplace \
#     -o custom-columns=NAME:.metadata.name,CATALOG:.status.catalogSource,DEFAULT:.status.defaultChannel,CHANNELS:.status.channels[*].name \
#     | grep -E 'NAME|cluster-logging|loki-operator|cluster-observability'
CLUSTER_LOGGING_CHANNEL="stable-6.7"
LOKI_OPERATOR_CHANNEL="stable-6.7"
COO_CHANNEL="stable"
OPERATOR_SOURCE="redhat-operators"
OPERATOR_SOURCE_NAMESPACE="openshift-marketplace"

# --- S4 only (STORAGE_BACKEND=s4) ---
# Must match router wildcard (*.apps.<cluster>) — use one DNS label, e.g. s3-s4.apps.… not s3.s4.apps.…
S4_API_HOST="s3-s4.apps.ebdn-rd3.ebeaudoi.tamlab.rdu2.redhat.com"
S4_ACCESS_KEY="s4admin"
S4_SECRET_KEY="s4secret"
S4_UI_PASSWORD="changeme"
# After ./deploy-s4.sh succeeds, set true and re-run to refresh Loki TLS CA.
S4_DEPLOYED_ON_CLUSTER=true

# --- External S3 only (STORAGE_BACKEND=s3) ---
S3_ENDPOINT="https://s3.example.com"
S3_ACCESS_KEY="CHANGE_ME_ACCESS_KEY"
S3_SECRET_KEY="CHANGE_ME_SECRET_KEY"
S3_BUCKET="loggingstack"

# --- GitOps / Argo CD ---
GIT_REPO_URL="https://github.com/ebeaudoin/deploy-gitops-logging.git"

# =============================================================================
# Fixed defaults (not edited per cluster)
# =============================================================================

S4_NAMESPACE="s4"
S4_API_ROUTE_NAME="s4-api"
S4_UI_USERNAME="admin"
S4_BUCKET_NAME="loggingstack"
S4_OVERLAY_TEMPLATE="lab"

LOKI_S3_SECRET_NAME="logging-loki-s3"
LOKI_S3_SECRET_TYPE="s3"
LOKI_S3_FORCE_PATH_STYLE="true"
LOKI_TLS_CA_NAME="loki-s3-ca-bundle"
LOKI_TLS_CA_NAME_ODF="openshift-service-ca.crt"
LOKI_SCHEMA_EFFECTIVE_DATE="2026-06-15"
LOKI_SCHEMA_VERSION="v13"
LOKI_SIZE="1x.pico"
LOKI_RETENTION_DAYS="14"
LOKI_NODE_SELECTOR_KEY="node-role.kubernetes.io/infra"
LOKI_NODE_SELECTOR_VALUE=""
LOKI_TOLERATION_KEY="node-role.kubernetes.io/infra"
LOKI_TOLERATION_VALUE=""
LOKI_TOLERATION_EFFECT="NoSchedule"

ODF_OBC_NAME="logging-loki-obc"
ODF_GENERATE_BUCKET_NAME="logging-loki"
ODF_STORAGE_CLASS="openshift-storage.noobaa.io"

KUBECONFIG_PATH="${HOME}/ocpkubeconfig"
GIT_TARGET_REVISION="HEAD"
GIT_PROTOCOL="https"
GIT_SSH_USER="git"
GIT_SSH_HOST=""
GIT_SSH_PORT=""
GIT_REPO_PATH=""
GIT_SSH_PRIVATE_KEY_FILE="${HOME}/.ssh/id_ed25519"
GIT_SSH_INSECURE_IGNORE_HOST_KEY="true"
GIT_TLS_INSECURE="true"
GIT_USERNAME=""
GIT_PASSWORD=""

# =============================================================================
# Runtime paths (populated by resolve_* — do not edit)
# =============================================================================

OVERLAY_DIR=""
LOKI_TEMPLATE=""
LOKI_STORAGE_PATCH=""
LOKI_CR_PATCH=""
LOKI_PLACEMENT_PATCH=""
LOKI_CA_PATCH=""
ODF_OBC_FILE=""
ODF_CR_PATCH=""
S4_ENABLED=false
S4_OVERLAY=""
S4_OVERLAY_DIR=""
S4_ROUTE_PATCH=""
S4_SECRET_PATCH=""
LOKI_S3_ACCESS_KEY_ID=""
LOKI_S3_ACCESS_KEY_SECRET=""
LOKI_S3_BUCKET=""
LOKI_S3_ENDPOINT=""
LOGGING_INSTANCE_APP_ARGO="${LOGGING_ARGOCD_DIR}/loki-instance-app-argo.yaml"
LOGGING_OPERATOR_APP_ARGO="${LOGGING_ARGOCD_DIR}/loggingoperator-app-argo.yaml"
LOKI_OPERATOR_APP_ARGO="${LOGGING_ARGOCD_DIR}/lokioperator-app-argo.yaml"
COO_APP_ARGO="${LOGGING_ARGOCD_DIR}/coo-app-argo.yaml"
APPLOGGING_PROJECT="${LOGGING_ARGOCD_DIR}/applogging-project.yaml"
CLUSTER_CONFIG_PROJECT="${APP_OF_APPS_DIR}/cluster-config-project.yaml"
GIT_REPO_SECRET="${GITOPS_DIR}/git-repository-secret.yaml"

LOGGING_OPERATOR_OVERLAY_DIR=""
LOKI_OPERATOR_OVERLAY_DIR=""
COO_OVERLAY_DIR=""

# shellcheck source=gitops/git-configure-lib.sh
source "${GITOPS_DIR}/git-configure-lib.sh"

# Normalize HEADER into internal settings used by the writers below.
apply_header_defaults() {
  STORAGE_BACKEND="$(echo "${STORAGE_BACKEND}" | tr '[:upper:]' '[:lower:]')"
  validate_overlay_name OVERLAY "${OVERLAY}"
  S4_OVERLAY="${OVERLAY}"

  case "${STORAGE_BACKEND}" in
    s4)
      S4_ENABLED=true
      LOKI_TEMPLATE="s3"
      LOKI_S3_ACCESS_KEY_ID="${S4_ACCESS_KEY}"
      LOKI_S3_ACCESS_KEY_SECRET="${S4_SECRET_KEY}"
      LOKI_S3_ENDPOINT="https://${S4_API_HOST}"
      LOKI_S3_BUCKET="${S4_BUCKET_NAME}"
      ;;
    s3)
      S4_ENABLED=false
      LOKI_TEMPLATE="s3"
      LOKI_S3_ACCESS_KEY_ID="${S3_ACCESS_KEY}"
      LOKI_S3_ACCESS_KEY_SECRET="${S3_SECRET_KEY}"
      LOKI_S3_ENDPOINT="${S3_ENDPOINT}"
      LOKI_S3_BUCKET="${S3_BUCKET}"
      ;;
    odf)
      S4_ENABLED=false
      LOKI_TEMPLATE="odf"
      LOKI_S3_ACCESS_KEY_ID=""
      LOKI_S3_ACCESS_KEY_SECRET=""
      LOKI_S3_ENDPOINT=""
      LOKI_S3_BUCKET=""
      ;;
    *)
      echo "ERROR: STORAGE_BACKEND must be 's4', 's3', or 'odf' (got '${STORAGE_BACKEND}')" >&2
      exit 1
      ;;
  esac

  if [[ "${GIT_REPO_URL}" == ssh://* || "${GIT_REPO_URL}" == git@* ]]; then
    GIT_PROTOCOL="ssh"
  else
    GIT_PROTOCOL="https"
  fi

  if [[ "${OPERATOR_SOURCE}" != "redhat-operators" ]]; then
    echo "ERROR: OPERATOR_SOURCE must be 'redhat-operators' (got '${OPERATOR_SOURCE}')." >&2
    exit 1
  fi
  if [[ "${OPERATOR_SOURCE_NAMESPACE}" != "openshift-marketplace" ]]; then
    echo "ERROR: OPERATOR_SOURCE_NAMESPACE must be 'openshift-marketplace' (got '${OPERATOR_SOURCE_NAMESPACE}')." >&2
    exit 1
  fi
}

# =============================================================================
# Helpers
# =============================================================================

b64() {
  printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64
}

indent_pem() {
  sed 's/^/    /'
}

validate_overlay_name() {
  local var_name="$1"
  local value="$2"
  if [[ -z "${value}" || "${value}" == *"/"* || "${value}" == "."* || "${value}" == *".."* ]]; then
    echo "ERROR: invalid ${var_name} '${value}' (use a bare directory name, e.g. s3, odf, lab)" >&2
    exit 1
  fi
}

host_from_endpoint() {
  local endpoint="$1"
  local rest
  rest="${endpoint#https://}"
  rest="${rest#http://}"
  rest="${rest%%/*}"
  printf '%s' "${rest%%:*}"
}

loki_toleration_yaml() {
  if [[ -n "${LOKI_TOLERATION_VALUE}" ]]; then
    cat <<EOF
        - effect: ${LOKI_TOLERATION_EFFECT}
          key: ${LOKI_TOLERATION_KEY}
          operator: Equal
          value: ${LOKI_TOLERATION_VALUE}
EOF
  else
    cat <<EOF
        - effect: ${LOKI_TOLERATION_EFFECT}
          key: ${LOKI_TOLERATION_KEY}
          operator: Exists
EOF
  fi
}

resolve_overlay_paths() {
  local template_dir="${REPO_ROOT}/logging/loki-instance/overlays/${LOKI_TEMPLATE}"
  OVERLAY_DIR="${REPO_ROOT}/logging/loki-instance/overlays/${OVERLAY}"

  if [[ ! -d "${OVERLAY_DIR}" ]]; then
    if [[ ! -d "${template_dir}" ]]; then
      echo "ERROR: overlay template missing: ${template_dir}" >&2
      exit 1
    fi
    echo "Seeding overlay '${OVERLAY}' from ${LOKI_TEMPLATE}"
    mkdir -p "${OVERLAY_DIR}"
    cp -a "${template_dir}/." "${OVERLAY_DIR}/"
  fi

  LOKI_CR_PATCH="${OVERLAY_DIR}/lokistack-cr-patch.yaml"
  LOKI_PLACEMENT_PATCH="${OVERLAY_DIR}/lokistack-placement-patch.yaml"
  LOKI_STORAGE_PATCH="${OVERLAY_DIR}/lokistack-storage-patch.yaml"
  LOKI_CA_PATCH="${OVERLAY_DIR}/loki-s3-ca-bundle-patch.yaml"
  ODF_OBC_FILE="${OVERLAY_DIR}/objectbucketclaim.yaml"
  ODF_CR_PATCH="${LOKI_CR_PATCH}"
}

resolve_s4_overlay_paths() {
  local template_dir="${REPO_ROOT}/s4/overlays/${S4_OVERLAY_TEMPLATE}"
  S4_OVERLAY_DIR="${REPO_ROOT}/s4/overlays/${S4_OVERLAY}"

  if [[ ! -d "${S4_OVERLAY_DIR}" ]]; then
    if [[ ! -d "${template_dir}" ]]; then
      echo "ERROR: S4 overlay template missing: ${template_dir}" >&2
      exit 1
    fi
    echo "Seeding S4 overlay '${S4_OVERLAY}' from ${S4_OVERLAY_TEMPLATE}"
    mkdir -p "${S4_OVERLAY_DIR}"
    cp -a "${template_dir}/." "${S4_OVERLAY_DIR}/"
  fi

  S4_ROUTE_PATCH="${S4_OVERLAY_DIR}/s4-route-s3-patch.yaml"
  S4_SECRET_PATCH="${S4_OVERLAY_DIR}/s4-secret-patch.yaml"
}

maybe_resolve_s4_host_from_cluster() {
  if [[ ! -f "${KUBECONFIG_PATH}" ]] || ! command -v oc >/dev/null 2>&1; then
    return 0
  fi

  local live_host
  live_host="$(
    oc --kubeconfig "${KUBECONFIG_PATH}" get route "${S4_API_ROUTE_NAME}" \
      -n "${S4_NAMESPACE}" \
      -o jsonpath='{.spec.host}' 2>/dev/null || true
  )"

  if [[ -n "${live_host}" ]]; then
    echo "Resolved live S4 API Route host: ${live_host}"
    S4_API_HOST="${live_host}"
  fi
}

# =============================================================================
# Argo CD writers
# =============================================================================

update_repo_url_and_revision() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo "WARNING: skip missing Argo CD file: ${file}" >&2
    return 0
  fi
  python3 - "${file}" "${GIT_REPO_URL}" "${GIT_TARGET_REVISION}" <<'PY'
import pathlib, sys
path, url, rev = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
out = []
for line in text.splitlines(keepends=True):
    stripped = line.lstrip()
    indent = line[: len(line) - len(stripped)]
    if stripped.startswith("repoURL:"):
        out.append(f"{indent}repoURL: {url}\n")
    elif stripped.startswith("targetRevision:"):
        out.append(f"{indent}targetRevision: {rev}\n")
    elif stripped.startswith("url:") and "stringData" in text:
        out.append(f"{indent}url: {url}\n")
    else:
        out.append(line)
path.write_text("".join(out))
print(f"Updated {path}")
PY
}

update_source_path() {
  local file="$1"
  local source_path="$2"
  if [[ ! -f "${file}" ]]; then
    echo "WARNING: skip missing Argo CD file: ${file}" >&2
    return 0
  fi
  python3 - "${file}" "${source_path}" <<'PY'
import pathlib, sys
path, source_path = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
out = []
replaced = 0
for line in text.splitlines(keepends=True):
    stripped = line.lstrip()
    indent = line[: len(line) - len(stripped)]
    if stripped.startswith("path:"):
        out.append(f"{indent}path: {source_path}\n")
        replaced += 1
    else:
        out.append(line)
if replaced == 0:
    raise SystemExit(f"ERROR: could not find path: in {path}")
path.write_text("".join(out))
print(f"Updated {path} path -> {source_path}")
PY
}

write_source_repos_project() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo "WARNING: skip missing AppProject: ${file}" >&2
    return 0
  fi
  python3 - "${file}" "${GIT_REPO_URL}" <<'PY'
import pathlib, sys, re
path, url = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
new, n = re.subn(
    r"(sourceRepos:\n\s*-\s+)\S+",
    rf"\g<1>{url}",
    text,
    count=1,
)
if n == 0:
    raise SystemExit(f"ERROR: could not find sourceRepos in {path}")
path.write_text(new)
print(f"Updated {path} sourceRepos -> {url}")
PY
}

update_applicationset_repo() {
  if [[ ! -f "${APPSET_FILE}" ]]; then
    return 0
  fi
  update_repo_url_and_revision "${APPSET_FILE}"
}

configure_argocd_git() {
  echo
  echo "=== Argo CD Git repository ==="
  resolve_git_repo_settings
  echo "  GIT_PROTOCOL=${GIT_PROTOCOL}"
  echo "  GIT_REPO_URL=${GIT_REPO_URL}"
  echo "  GIT_TARGET_REVISION=${GIT_TARGET_REVISION}"
  echo "  OVERLAY=${OVERLAY}"

  write_git_repository_secret

  local app
  for app in \
    "${LOGGING_OPERATOR_APP_ARGO}" \
    "${LOKI_OPERATOR_APP_ARGO}" \
    "${LOGGING_INSTANCE_APP_ARGO}" \
    "${COO_APP_ARGO}" \
    "${LOGGING_ARGOCD_DIR}/logginginstance-app-argo.yaml" \
    "${APP_OF_APPS_DIR}/logging-apps.yaml"
  do
    update_repo_url_and_revision "${app}"
  done

  update_source_path \
    "${LOGGING_OPERATOR_APP_ARGO}" \
    "logging/operator/overlays/${OVERLAY}"
  update_source_path \
    "${LOKI_OPERATOR_APP_ARGO}" \
    "logging/loki-operator/overlays/${OVERLAY}"
  update_source_path \
    "${COO_APP_ARGO}" \
    "logging/coo/overlays/${OVERLAY}"
  update_source_path \
    "${LOGGING_INSTANCE_APP_ARGO}" \
    "logging/loki-instance/overlays/${OVERLAY}"

  write_source_repos_project "${APPLOGGING_PROJECT}"
  write_source_repos_project "${CLUSTER_CONFIG_PROJECT}"
  update_applicationset_repo
}

# =============================================================================
# Overlay writers
# =============================================================================

ensure_operator_overlay() {
  # $1 = component dir under logging/
  # $2 = Subscription name
  # $3 = Subscription namespace
  # Sets RESULT_DIR to the overlay path.
  local component="$1"
  local sub_name="$2"
  local sub_ns="$3"
  local base_dir="${REPO_ROOT}/logging/${component}/base"
  local overlay_dir="${REPO_ROOT}/logging/${component}/overlays/${OVERLAY}"

  if [[ ! -d "${base_dir}" ]]; then
    echo "ERROR: missing operator base: ${base_dir}" >&2
    exit 1
  fi

  mkdir -p "${overlay_dir}"
  cat > "${overlay_dir}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - path: subscription-patch.yaml
    target:
      group: operators.coreos.com
      version: v1alpha1
      kind: Subscription
      name: ${sub_name}
      namespace: ${sub_ns}
EOF
  echo "Updated ${overlay_dir}/kustomization.yaml"

  RESULT_DIR="${overlay_dir}"
}

write_subscription_channel_patch() {
  # $1 = overlay dir, $2 = subscription name, $3 = namespace, $4 = channel
  local overlay_dir="$1"
  local sub_name="$2"
  local sub_ns="$3"
  local channel="$4"
  local patch_file="${overlay_dir}/subscription-patch.yaml"

  cat > "${patch_file}" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${sub_name}
  namespace: ${sub_ns}
spec:
  channel: ${channel}
  source: ${OPERATOR_SOURCE}
  sourceNamespace: ${OPERATOR_SOURCE_NAMESPACE}
EOF
  echo "Updated ${patch_file}"
}

configure_operator_overlays() {
  echo
  echo "=== Operator Subscription overlays ==="
  echo "  OVERLAY=${OVERLAY}"
  echo "  CLUSTER_LOGGING_CHANNEL=${CLUSTER_LOGGING_CHANNEL}"
  echo "  LOKI_OPERATOR_CHANNEL=${LOKI_OPERATOR_CHANNEL}"
  echo "  COO_CHANNEL=${COO_CHANNEL}"
  echo "  OPERATOR_SOURCE=${OPERATOR_SOURCE}"

  : "${CLUSTER_LOGGING_CHANNEL:?CLUSTER_LOGGING_CHANNEL is required}"
  : "${LOKI_OPERATOR_CHANNEL:?LOKI_OPERATOR_CHANNEL is required}"
  : "${COO_CHANNEL:?COO_CHANNEL is required}"
  : "${OPERATOR_SOURCE:?OPERATOR_SOURCE is required}"
  : "${OPERATOR_SOURCE_NAMESPACE:?OPERATOR_SOURCE_NAMESPACE is required}"

  ensure_operator_overlay "operator" "cluster-logging" "openshift-logging"
  LOGGING_OPERATOR_OVERLAY_DIR="${RESULT_DIR}"
  write_subscription_channel_patch \
    "${LOGGING_OPERATOR_OVERLAY_DIR}" \
    "cluster-logging" \
    "openshift-logging" \
    "${CLUSTER_LOGGING_CHANNEL}"

  ensure_operator_overlay "loki-operator" "loki-operator" "openshift-operators-redhat"
  LOKI_OPERATOR_OVERLAY_DIR="${RESULT_DIR}"
  write_subscription_channel_patch \
    "${LOKI_OPERATOR_OVERLAY_DIR}" \
    "loki-operator" \
    "openshift-operators-redhat" \
    "${LOKI_OPERATOR_CHANNEL}"

  ensure_operator_overlay "coo" "cluster-observability-operator" "openshift-cluster-observability-operator"
  COO_OVERLAY_DIR="${RESULT_DIR}"
  write_subscription_channel_patch \
    "${COO_OVERLAY_DIR}" \
    "cluster-observability-operator" \
    "openshift-cluster-observability-operator" \
    "${COO_CHANNEL}"
}

write_s4_route_patch() {
  cat > "${S4_ROUTE_PATCH}" <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: s4-api
spec:
  host: ${S4_API_HOST}
EOF
  echo "Updated ${S4_ROUTE_PATCH}"
}

write_s4_secret_patch() {
  cat > "${S4_SECRET_PATCH}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: s4-credentials
stringData:
  AWS_ACCESS_KEY_ID: ${S4_ACCESS_KEY}
  AWS_SECRET_ACCESS_KEY: ${S4_SECRET_KEY}
  UI_USERNAME: ${S4_UI_USERNAME}
  UI_PASSWORD: ${S4_UI_PASSWORD}
EOF
  echo "Updated ${S4_SECRET_PATCH}"
}

write_loki_storage_patch() {
  local access_key_b64 secret_b64 bucket_b64 endpoint_b64 force_b64
  access_key_b64="$(b64 "${LOKI_S3_ACCESS_KEY_ID}")"
  secret_b64="$(b64 "${LOKI_S3_ACCESS_KEY_SECRET}")"
  bucket_b64="$(b64 "${LOKI_S3_BUCKET}")"
  endpoint_b64="$(b64 "${LOKI_S3_ENDPOINT}")"
  force_b64="$(b64 "${LOKI_S3_FORCE_PATH_STYLE}")"

  cat > "${LOKI_STORAGE_PATCH}" <<EOF
# Overrides logging/loki-instance/base/logging-loki-s3.yaml.
# Values must be base64-encoded. Generated by configure-overlays.sh.
- op: replace
  path: /data/access_key_id
  value: ${access_key_b64}
- op: replace
  path: /data/access_key_secret
  value: ${secret_b64}
- op: replace
  path: /data/bucketnames
  value: ${bucket_b64}
- op: replace
  path: /data/endpoint
  value: ${endpoint_b64}
- op: replace
  path: /data/forcepathstyle
  value: ${force_b64}
EOF
  echo "Updated ${LOKI_STORAGE_PATCH}"
}

write_loki_cr_patch_s3() {
  cat > "${LOKI_CR_PATCH}" <<EOF
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  size: ${LOKI_SIZE}
  limits:
    global:
      retention:
        days: ${LOKI_RETENTION_DAYS}
  storage:
    schemas:
      - effectiveDate: "${LOKI_SCHEMA_EFFECTIVE_DATE}"
        version: ${LOKI_SCHEMA_VERSION}
    secret:
      name: ${LOKI_S3_SECRET_NAME}
      type: ${LOKI_S3_SECRET_TYPE}
    tls:
      caName: ${LOKI_TLS_CA_NAME}
  storageClassName: ${LOKI_STORAGE_CLASS}
EOF
  echo "Updated ${LOKI_CR_PATCH}"
}

write_loki_cr_patch_odf() {
  cat > "${ODF_CR_PATCH}" <<EOF
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  size: ${LOKI_SIZE}
  limits:
    global:
      retention:
        days: ${LOKI_RETENTION_DAYS}
  storage:
    schemas:
      - effectiveDate: "${LOKI_SCHEMA_EFFECTIVE_DATE}"
        version: ${LOKI_SCHEMA_VERSION}
    secret:
      name: ${LOKI_S3_SECRET_NAME}
      type: ${LOKI_S3_SECRET_TYPE}
    tls:
      caName: ${LOKI_TLS_CA_NAME_ODF}
  storageClassName: ${LOKI_STORAGE_CLASS}
EOF
  echo "Updated ${ODF_CR_PATCH}"
}

write_loki_placement_patch() {
  local toleration
  toleration="$(loki_toleration_yaml)"

  {
    cat <<EOF
# Overrides LokiStack infra node placement from base.
# Generated by configure-overlays.sh.
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  template:
EOF
    for component in compactor distributor gateway indexGateway ingester querier queryFrontend ruler; do
      cat <<EOF
    ${component}:
      nodeSelector:
        ${LOKI_NODE_SELECTOR_KEY}: "${LOKI_NODE_SELECTOR_VALUE}"
      tolerations:
${toleration}
EOF
    done
  } > "${LOKI_PLACEMENT_PATCH}"
  echo "Updated ${LOKI_PLACEMENT_PATCH}"
}

write_odf_obc() {
  cat > "${ODF_OBC_FILE}" <<EOF
# OpenShift Data Foundation (NooBaa / MCG) bucket for Loki.
# Generated by configure-overlays.sh.
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ${ODF_OBC_NAME}
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  generateBucketName: ${ODF_GENERATE_BUCKET_NAME}
  storageClassName: ${ODF_STORAGE_CLASS}
EOF
  echo "Updated ${ODF_OBC_FILE}"

  # Keep Job env OBC_NAME in sync when the overlay was seeded.
  local job="${OVERLAY_DIR}/odf-secret-sync-job.yaml"
  if [[ -f "${job}" ]]; then
    python3 - "${job}" "${ODF_OBC_NAME}" "${LOKI_S3_SECRET_NAME}" <<'PY'
import pathlib, sys
path, obc, secret = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
out = []
pending = None
for line in text.splitlines(keepends=True):
    stripped = line.lstrip()
    indent = line[: len(line) - len(stripped)]
    if stripped.startswith("name: OBC_NAME"):
        pending = "obc"
        out.append(line)
    elif stripped.startswith("name: LOKI_SECRET_NAME"):
        pending = "secret"
        out.append(line)
    elif pending == "obc" and stripped.startswith("value:"):
        out.append(f"{indent}value: {obc}\n")
        pending = None
    elif pending == "secret" and stripped.startswith("value:"):
        out.append(f"{indent}value: {secret}\n")
        pending = None
    else:
        out.append(line)
path.write_text("".join(out))
print(f"Updated {path} OBC/secret env refs")
PY
  fi
}

fetch_s3_ca_pem() {
  local host="$1"
  local chain tmp_dir leaf issuer

  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is required to fetch the S3 TLS CA" >&2
    exit 1
  fi

  echo "Fetching TLS certificate chain from ${host}:443 ..." >&2
  chain="$(
    echo | openssl s_client -showcerts -servername "${host}" -connect "${host}:443" 2>/dev/null \
      | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p'
  )"

  if [[ -z "${chain}" ]]; then
    echo "ERROR: could not retrieve certificates from ${host}:443" >&2
    exit 1
  fi

  tmp_dir="$(mktemp -d "${HOME}/.deploy-gitops-logging-s3-ca.XXXXXX")"
  awk -v out="${tmp_dir}" '
    /BEGIN CERTIFICATE/ { n++; f=sprintf("%s/cert-%d.pem", out, n-1); }
    { print > f }
  ' <<<"${chain}"

  leaf="${tmp_dir}/cert-0.pem"
  issuer="${tmp_dir}/cert-1.pem"

  if [[ -f "${issuer}" ]]; then
    cat "${issuer}"
  else
    echo "WARNING: only one certificate returned; using leaf cert as CA bundle" >&2
    cat "${leaf}"
  fi

  rm -rf "${tmp_dir}"
}

write_loki_ca_bundle_patch() {
  local ca_pem indented host
  host="$(host_from_endpoint "${LOKI_S3_ENDPOINT}")"
  ca_pem="$(fetch_s3_ca_pem "${host}")"
  indented="$(indent_pem <<<"${ca_pem}")"

  cat > "${LOKI_CA_PATCH}" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-s3-ca-bundle
  namespace: openshift-logging
data:
  # CA that signs the object-storage API certificate.
  # Generated by configure-overlays.sh from ${host}.
  service-ca.crt: |
${indented}
EOF
  echo "Updated ${LOKI_CA_PATCH}"
}

configure_s4_overlays() {
  echo
  echo "=== S4 overlays ==="
  echo "  OVERLAY=${S4_OVERLAY}"
  echo "  S4_API_HOST=${S4_API_HOST}"
  echo "  S4_DEPLOYED_ON_CLUSTER=${S4_DEPLOYED_ON_CLUSTER}"

  if [[ "${S4_ENABLED}" != "true" ]]; then
    echo "STORAGE_BACKEND!=s4 — skipping s4/overlays patches"
    return 0
  fi

  if [[ "${S4_DEPLOYED_ON_CLUSTER}" == "true" ]]; then
    maybe_resolve_s4_host_from_cluster
    LOKI_S3_ENDPOINT="https://${S4_API_HOST}"
  fi

  : "${S4_API_HOST:?S4_API_HOST is required when STORAGE_BACKEND=s4}"
  : "${S4_ACCESS_KEY:?S4_ACCESS_KEY is required when STORAGE_BACKEND=s4}"
  : "${S4_SECRET_KEY:?S4_SECRET_KEY is required when STORAGE_BACKEND=s4}"
  : "${S4_UI_PASSWORD:?S4_UI_PASSWORD is required when STORAGE_BACKEND=s4}"

  resolve_s4_overlay_paths
  write_s4_route_patch
  write_s4_secret_patch

  echo "  Loki S3 endpoint=${LOKI_S3_ENDPOINT} bucket=${LOKI_S3_BUCKET}"
}

configure_s3_loki_overlay() {
  : "${LOKI_S3_ACCESS_KEY_ID:?S3 access key is required}"
  : "${LOKI_S3_ACCESS_KEY_SECRET:?S3 secret key is required}"
  : "${LOKI_S3_ENDPOINT:?S3 endpoint is required}"
  : "${LOKI_S3_BUCKET:?S3 bucket is required}"

  write_loki_storage_patch
  write_loki_cr_patch_s3
  write_loki_placement_patch

  # Refresh CA when S4 is live, or always for external S3.
  if [[ "${STORAGE_BACKEND}" == "s4" && "${S4_DEPLOYED_ON_CLUSTER}" != "true" ]]; then
    echo "Skipping Loki TLS CA update (set S4_DEPLOYED_ON_CLUSTER=true after ./deploy-s4.sh)"
  else
    write_loki_ca_bundle_patch
  fi
}

configure_odf_overlay() {
  write_odf_obc
  write_loki_cr_patch_odf
  write_loki_placement_patch
}

configure_overlays() {
  echo
  echo "=== Logging overlays ==="
  echo "  STORAGE_BACKEND=${STORAGE_BACKEND}"
  echo "  OVERLAY=${OVERLAY}"
  echo "  LOKI_STORAGE_CLASS=${LOKI_STORAGE_CLASS}"

  configure_operator_overlays
  configure_s4_overlays

  resolve_overlay_paths
  echo "  OVERLAY_DIR=${OVERLAY_DIR}"

  case "${LOKI_TEMPLATE}" in
    s3) configure_s3_loki_overlay ;;
    odf) configure_odf_overlay ;;
  esac
}

# =============================================================================
# Main
# =============================================================================

main() {
  if [[ $# -gt 0 ]]; then
    echo "ERROR: this script takes no parameters." >&2
    echo "Edit the HEADER variables in configure-overlays.sh, then run: ./configure-overlays.sh" >&2
    exit 1
  fi

  apply_header_defaults

  echo "Configuring overlay patches from HEADER..."
  echo "  STORAGE_BACKEND=${STORAGE_BACKEND}"
  echo "  OVERLAY=${OVERLAY}"
  echo "  LOKI_STORAGE_CLASS=${LOKI_STORAGE_CLASS}"
  echo "  CLUSTER_LOGGING_CHANNEL=${CLUSTER_LOGGING_CHANNEL}"
  echo "  LOKI_OPERATOR_CHANNEL=${LOKI_OPERATOR_CHANNEL}"
  echo "  COO_CHANNEL=${COO_CHANNEL}"
  echo "  GIT_REPO_URL=${GIT_REPO_URL}"
  echo "  GIT_TARGET_REVISION=${GIT_TARGET_REVISION}"

  : "${GIT_REPO_URL:?GIT_REPO_URL is required}"
  : "${LOKI_STORAGE_CLASS:?LOKI_STORAGE_CLASS is required}"

  configure_overlays
  configure_argocd_git

  echo
  echo "Done. Review git diff, then commit/push so Argo CD can sync."
  echo "  Kustomize: oc apply -k logging/...  (see README)"
  echo "  GitOps:    oc apply -k gitops/app-of-apps"
  if [[ "${STORAGE_BACKEND}" == "s4" ]]; then
    echo "  S4:        ./deploy-s4.sh  then set S4_DEPLOYED_ON_CLUSTER=true and re-run"
  fi
  if [[ "${STORAGE_BACKEND}" == "odf" ]]; then
    echo "  ODF: wait for ObjectBucketClaim Bound + loki-odf-secret-sync Job."
  fi
}

main "$@"
