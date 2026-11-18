#!/usr/bin/env bash
# =============================================================================
# configure-overlays.sh
#
# Idempotent overlay updater for OpenShift Logging (LokiStack + GitOps).
#
# Usage:
#   1) Edit every value in the HEADER section below (no CLI parameters).
#   2) Run:  ./configure-overlays.sh
#
# What it updates:
#   logging/loki-instance/overlays/<OVERLAY>/  (seeded from s3 or odf template)
#   s4/overlays/<S4_OVERLAY>/                  (when S4_ENABLED=true)
#   logging/argoCD/*  (repoURL, targetRevision, loki-instance path)
#   gitops/app-of-apps/*  (repoURL, targetRevision)
#   gitops/applicationset/logging-applicationset.yaml
#   gitops/git-repository-secret.yaml
#
# Typical S4 lab flow:
#   1) Edit HEADER (S4_* + Loki STORAGE_BACKEND=s3)
#   2) ./configure-overlays.sh
#   3) ./deploy-s4.sh
#   4) Set S4_DEPLOYED_ON_CLUSTER=true, re-run ./configure-overlays.sh
#   5) Deploy logging (oc apply -k … or GitOps)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
LOGGING_ARGOCD_DIR="${REPO_ROOT}/logging/argoCD"
APP_OF_APPS_DIR="${REPO_ROOT}/gitops/app-of-apps"
GITOPS_DIR="${REPO_ROOT}/gitops"
APPSET_FILE="${GITOPS_DIR}/applicationset/logging-applicationset.yaml"

# =============================================================================
# HEADER — edit these values for your lab / cluster
# Do not pass CLI parameters; change variables here, then run the script.
# =============================================================================

# --- Storage backend: s3 | odf ---
# s3  = external S3-compatible (AWS, MinIO, in-repo S4, Ceph RGW, …)
# odf = OpenShift Data Foundation ObjectBucketClaim / NooBaa MCG
STORAGE_BACKEND="s3"

# Overlay directory under logging/loki-instance/overlays/<OVERLAY>
# New names are seeded from the matching template (s3 or odf).
OVERLAY="s3"

# --- In-repo S4 object storage (optional; pairs with STORAGE_BACKEND=s3) ---
# Set S4_ENABLED=true to write s4/overlays/<S4_OVERLAY> patches and to sync
# Loki S3 endpoint/credentials from the S4_* values below.
S4_ENABLED=true
# After ./deploy-s4.sh succeeds, set true and re-run this script to refresh
# the Loki TLS CA from the live S4 API route.
S4_DEPLOYED_ON_CLUSTER=false
S4_OVERLAY="lab"                          # seeded from s4/overlays/lab if missing
S4_NAMESPACE="s4"
S4_API_ROUTE_NAME="s4-api"                # OpenShift Route object name
S4_API_HOST="s3.s4.apps.example.com"      # S3 Route hostname (not the UI Route)
S4_AWS_ACCESS_KEY_ID="s4admin"
S4_AWS_SECRET_ACCESS_KEY="s4secret"
S4_UI_USERNAME="admin"
S4_UI_PASSWORD="changeme"
S4_BUCKET_NAME="loggingstack"             # created by ./deploy-s4.sh

# --- S3 parameters (used when STORAGE_BACKEND=s3) ---
# When S4_ENABLED=true these access/endpoint/bucket fields are overwritten from S4_*.
LOKI_S3_ACCESS_KEY_ID="CHANGE_ME_ACCESS_KEY"
LOKI_S3_ACCESS_KEY_SECRET="CHANGE_ME_SECRET_KEY"
LOKI_S3_BUCKET="loggingstack"
LOKI_S3_ENDPOINT="https://s3.example.com"
LOKI_S3_REGION=""                         # optional; leave empty if unused
LOKI_S3_FORCE_PATH_STYLE="true"
LOKI_S3_SECRET_NAME="logging-loki-s3"
LOKI_S3_SECRET_TYPE="s3"
LOKI_TLS_CA_NAME="loki-s3-ca-bundle"
# Set FETCH_S3_CA=true to refresh loki-s3-ca-bundle-patch.yaml from the endpoint.
# Also implied when S4_ENABLED=true and S4_DEPLOYED_ON_CLUSTER=true.
FETCH_S3_CA=false
# Optional PEM path; when set (and FETCH_S3_CA=true), used instead of a live fetch.
S3_CA_FILE=""

# --- ODF / ObjectBucketClaim parameters (used when STORAGE_BACKEND=odf) ---
ODF_OBC_NAME="logging-loki-obc"
ODF_GENERATE_BUCKET_NAME="logging-loki"
ODF_STORAGE_CLASS="openshift-storage.noobaa.io"
# LokiStack TLS CA ConfigMap name for NooBaa (usually cluster service CA).
LOKI_TLS_CA_NAME_ODF="openshift-service-ca.crt"

# --- LokiStack CR ---
LOKI_STORAGE_CLASS="gp3-csi"              # block StorageClass for Loki PVCs
LOKI_SCHEMA_EFFECTIVE_DATE="2026-06-15"
LOKI_SCHEMA_VERSION="v13"
LOKI_SIZE="1x.pico"
LOKI_RETENTION_DAYS="14"

# --- LokiStack infra placement ---
# Empty LOKI_TOLERATION_VALUE => toleration operator Exists (no value field).
# Empty LOKI_NODE_SELECTOR_VALUE is valid (matches label key with empty value).
LOKI_NODE_SELECTOR_KEY="node-role.kubernetes.io/infra"
LOKI_NODE_SELECTOR_VALUE=""
LOKI_TOLERATION_KEY="node-role.kubernetes.io/infra"
LOKI_TOLERATION_VALUE=""
LOKI_TOLERATION_EFFECT="NoSchedule"

# --- Optional kubeconfig (used only if a future helper needs oc) ---
KUBECONFIG_PATH="${HOME}/ocpkubeconfig"

# --- Argo CD Git repository ---
# GIT_PROTOCOL=https|ssh. For SSH, set GIT_SSH_PORT (or the script prompts interactively)
# and it builds: ssh://git@HOST:PORT/ORG/REPO.git
GIT_PROTOCOL="https"
GIT_REPO_URL="https://github.com/EXAMPLE/deploy-gitops-logging.git"
GIT_TARGET_REVISION="HEAD"
# SSH (used when GIT_PROTOCOL=ssh; host/path can be parsed from GIT_REPO_URL)
GIT_SSH_USER="git"
GIT_SSH_HOST=""
GIT_SSH_PORT=""                            # prompted interactively if empty and protocol=ssh
GIT_REPO_PATH=""                          # e.g. org/deploy-gitops-logging.git
GIT_SSH_PRIVATE_KEY_FILE="${HOME}/.ssh/id_ed25519"
GIT_SSH_INSECURE_IGNORE_HOST_KEY="true"
# HTTPS
GIT_TLS_INSECURE="true"
GIT_USERNAME=""
GIT_PASSWORD=""
# Optional path written by gitops/collect-git-ca.sh (documentation / your apply step)
GIT_CA_FILE="gitops/git-ca.crt"

# =============================================================================
# Runtime paths (populated by resolve_* — do not edit)
# =============================================================================

OVERLAY_DIR=""
LOKI_STORAGE_PATCH=""
LOKI_CR_PATCH=""
LOKI_PLACEMENT_PATCH=""
LOKI_CA_PATCH=""
ODF_OBC_FILE=""
ODF_CR_PATCH=""
S4_OVERLAY_DIR=""
S4_ROUTE_PATCH=""
S4_SECRET_PATCH=""
S4_OVERLAY_TEMPLATE="lab"
LOGGING_INSTANCE_APP_ARGO="${LOGGING_ARGOCD_DIR}/loki-instance-app-argo.yaml"
APPLOGGING_PROJECT="${LOGGING_ARGOCD_DIR}/applogging-project.yaml"
CLUSTER_CONFIG_PROJECT="${APP_OF_APPS_DIR}/cluster-config-project.yaml"
GIT_REPO_SECRET="${GITOPS_DIR}/git-repository-secret.yaml"

# shellcheck source=gitops/git-configure-lib.sh
source "${GITOPS_DIR}/git-configure-lib.sh"

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
  validate_overlay_name OVERLAY "${OVERLAY}"
  STORAGE_BACKEND="$(echo "${STORAGE_BACKEND}" | tr '[:upper:]' '[:lower:]')"
  case "${STORAGE_BACKEND}" in
    s3|odf) ;;
    *)
      echo "ERROR: STORAGE_BACKEND must be 's3' or 'odf' (got '${STORAGE_BACKEND}')" >&2
      exit 1
      ;;
  esac

  local template_dir="${REPO_ROOT}/logging/loki-instance/overlays/${STORAGE_BACKEND}"
  OVERLAY_DIR="${REPO_ROOT}/logging/loki-instance/overlays/${OVERLAY}"

  if [[ ! -d "${OVERLAY_DIR}" ]]; then
    if [[ ! -d "${template_dir}" ]]; then
      echo "ERROR: overlay template missing: ${template_dir}" >&2
      exit 1
    fi
    echo "Seeding overlay '${OVERLAY}' from ${STORAGE_BACKEND}"
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
  validate_overlay_name S4_OVERLAY "${S4_OVERLAY}"

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

apply_s4_to_loki_s3_params() {
  # When using in-repo S4, Loki S3 fields follow S4_* so they cannot drift.
  LOKI_S3_ACCESS_KEY_ID="${S4_AWS_ACCESS_KEY_ID}"
  LOKI_S3_ACCESS_KEY_SECRET="${S4_AWS_SECRET_ACCESS_KEY}"
  LOKI_S3_ENDPOINT="https://${S4_API_HOST}"
  LOKI_S3_BUCKET="${S4_BUCKET_NAME}"
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
    "${LOGGING_ARGOCD_DIR}/loggingoperator-app-argo.yaml" \
    "${LOGGING_ARGOCD_DIR}/lokioperator-app-argo.yaml" \
    "${LOGGING_INSTANCE_APP_ARGO}" \
    "${LOGGING_ARGOCD_DIR}/coo-app-argo.yaml" \
    "${LOGGING_ARGOCD_DIR}/logginginstance-app-argo.yaml" \
    "${APP_OF_APPS_DIR}/logging-apps.yaml"
  do
    update_repo_url_and_revision "${app}"
  done

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
  AWS_ACCESS_KEY_ID: ${S4_AWS_ACCESS_KEY_ID}
  AWS_SECRET_ACCESS_KEY: ${S4_AWS_SECRET_ACCESS_KEY}
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

  {
    cat <<EOF
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
    if [[ -n "${LOKI_S3_REGION}" ]]; then
      cat <<EOF
- op: add
  path: /data/region
  value: $(b64 "${LOKI_S3_REGION}")
EOF
    fi
  } > "${LOKI_STORAGE_PATCH}"
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

  if [[ -n "${S3_CA_FILE}" ]]; then
    if [[ ! -f "${S3_CA_FILE}" ]]; then
      echo "ERROR: S3_CA_FILE not found: ${S3_CA_FILE}" >&2
      exit 1
    fi
    ca_pem="$(cat "${S3_CA_FILE}")"
    host="file:${S3_CA_FILE}"
  else
    host="$(host_from_endpoint "${LOKI_S3_ENDPOINT}")"
    ca_pem="$(fetch_s3_ca_pem "${host}")"
  fi
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
  echo "  S4_ENABLED=${S4_ENABLED}"
  echo "  S4_DEPLOYED_ON_CLUSTER=${S4_DEPLOYED_ON_CLUSTER}"
  echo "  S4_OVERLAY=${S4_OVERLAY}"
  echo "  S4_API_HOST=${S4_API_HOST}"

  if [[ "${S4_ENABLED}" != "true" ]]; then
    echo "S4_ENABLED=false — skipping s4/overlays patches"
    return 0
  fi

  if [[ "${S4_DEPLOYED_ON_CLUSTER}" == "true" ]]; then
    maybe_resolve_s4_host_from_cluster
  fi

  : "${S4_API_HOST:?S4_API_HOST is required when S4_ENABLED=true}"
  : "${S4_AWS_ACCESS_KEY_ID:?S4_AWS_ACCESS_KEY_ID is required when S4_ENABLED=true}"
  : "${S4_AWS_SECRET_ACCESS_KEY:?S4_AWS_SECRET_ACCESS_KEY is required when S4_ENABLED=true}"
  : "${S4_UI_USERNAME:?S4_UI_USERNAME is required when S4_ENABLED=true}"
  : "${S4_UI_PASSWORD:?S4_UI_PASSWORD is required when S4_ENABLED=true}"
  : "${S4_BUCKET_NAME:?S4_BUCKET_NAME is required when S4_ENABLED=true}"

  resolve_s4_overlay_paths
  write_s4_route_patch
  write_s4_secret_patch
  apply_s4_to_loki_s3_params

  echo "  Synced Loki S3 from S4: endpoint=${LOKI_S3_ENDPOINT} bucket=${LOKI_S3_BUCKET}"
}

configure_s3_overlay() {
  : "${LOKI_S3_ACCESS_KEY_ID:?LOKI_S3_ACCESS_KEY_ID is required}"
  : "${LOKI_S3_ACCESS_KEY_SECRET:?LOKI_S3_ACCESS_KEY_SECRET is required}"
  : "${LOKI_S3_ENDPOINT:?LOKI_S3_ENDPOINT is required}"
  : "${LOKI_S3_BUCKET:?LOKI_S3_BUCKET is required}"

  write_loki_storage_patch
  write_loki_cr_patch_s3
  write_loki_placement_patch

  local fetch_ca="${FETCH_S3_CA}"
  if [[ "${S4_ENABLED}" == "true" && "${S4_DEPLOYED_ON_CLUSTER}" == "true" ]]; then
    fetch_ca=true
  fi

  if [[ "${fetch_ca}" == "true" ]]; then
    write_loki_ca_bundle_patch
  else
    echo "Skipping Loki TLS CA update (set FETCH_S3_CA=true, or S4_ENABLED=true with S4_DEPLOYED_ON_CLUSTER=true)"
  fi
}

configure_odf_overlay() {
  : "${ODF_STORAGE_CLASS:?ODF_STORAGE_CLASS is required}"
  : "${ODF_OBC_NAME:?ODF_OBC_NAME is required}"
  : "${ODF_GENERATE_BUCKET_NAME:?ODF_GENERATE_BUCKET_NAME is required}"

  write_odf_obc
  write_loki_cr_patch_odf
  write_loki_placement_patch
}

configure_overlays() {
  echo
  echo "=== Logging overlays ==="
  echo "  STORAGE_BACKEND=${STORAGE_BACKEND}"
  echo "  OVERLAY=${OVERLAY}"
  echo "  S4_ENABLED=${S4_ENABLED}"
  echo "  LOKI_STORAGE_CLASS=${LOKI_STORAGE_CLASS}"
  echo "  LOKI_NODE_SELECTOR=${LOKI_NODE_SELECTOR_KEY}=${LOKI_NODE_SELECTOR_VALUE}"
  echo "  LOKI_TOLERATION=${LOKI_TOLERATION_KEY}=${LOKI_TOLERATION_VALUE}:${LOKI_TOLERATION_EFFECT}"

  configure_s4_overlays

  resolve_overlay_paths
  echo "  OVERLAY_DIR=${OVERLAY_DIR}"

  case "${STORAGE_BACKEND}" in
    s3) configure_s3_overlay ;;
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

  echo "Configuring overlay patches from HEADER..."
  echo "  STORAGE_BACKEND=${STORAGE_BACKEND}"
  echo "  OVERLAY=${OVERLAY}"
  echo "  S4_ENABLED=${S4_ENABLED}"
  echo "  S4_OVERLAY=${S4_OVERLAY}"
  echo "  GIT_PROTOCOL=${GIT_PROTOCOL}"
  echo "  GIT_REPO_URL=${GIT_REPO_URL}"
  echo "  GIT_TARGET_REVISION=${GIT_TARGET_REVISION}"

  : "${GIT_TARGET_REVISION:?GIT_TARGET_REVISION is required}"
  : "${LOKI_STORAGE_CLASS:?LOKI_STORAGE_CLASS is required}"

  configure_overlays
  configure_argocd_git

  echo
  echo "Done. Review git diff, then commit/push so Argo CD can sync."
  echo "  Kustomize path: see README (oc apply -k ...)"
  echo "  GitOps path:    oc apply -k gitops/app-of-apps"
  if [[ "${S4_ENABLED}" == "true" ]]; then
    echo "  S4:           ./deploy-s4.sh   (after configure; then set S4_DEPLOYED_ON_CLUSTER=true and re-run)"
  fi
  if [[ "${STORAGE_BACKEND}" == "odf" ]]; then
    echo "  ODF: after apply, wait for ObjectBucketClaim Bound + loki-odf-secret-sync Job."
  fi
}

main "$@"
