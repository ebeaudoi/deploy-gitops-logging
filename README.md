# OpenShift Logging (GitOps)

Standalone repository for deploying **OpenShift Logging** with LokiStack — no Keycloak or unrelated workloads.

Supports:

- **Pure Kustomize** (`oc apply -k`)
- **OpenShift GitOps (Argo CD)** App-of-Apps and optional **ApplicationSet**

Object storage backends:

| Backend | Overlay / package | When to use |
|---------|-------------------|-------------|
| **In-repo S4** | `s4/` + Loki `overlays/s3` | Lab/demo S3-compatible storage packaged in this repo ([S4](https://github.com/rh-aiservices-bu/s4)) |
| **External S3** | Loki `overlays/s3` | Existing AWS / MinIO / Ceph RGW / remote S4 |
| **ODF** | Loki `overlays/odf` | OpenShift Data Foundation NooBaa / MCG via `ObjectBucketClaim` |

---

## Index

- [Repository structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Storage configuration guide](#storage-configuration-guide)
  - [In-repo S4 (recommended for labs)](#in-repo-s4-recommended-for-labs)
  - [External S3](#external-s3)
  - [ODF (ObjectBucketClaim / NooBaa)](#odf-objectbucketclaim--noobaa)
- [Script usage](#script-usage)
- [Deploy with Kustomize only](#deploy-with-kustomize-only)
- [Deploy with OpenShift GitOps (Argo CD)](#deploy-with-openshift-gitops-argo-cd)
- [Verification](#verification)
- [Loki node placement](#loki-node-placement)

---

## Repository structure

```text
deploy-gitops-logging/
├── configure-overlays.sh          # Idempotent overlay / Argo URL updater (HEADER only)
├── deploy-s4.sh                   # Deploy S4 + create Loki bucket
├── scripts/
│   └── sync-odf-loki-secret.sh    # Manual ODF → Loki secret helper
├── s4/
│   ├── base/                      # S4 Deployment, Service, Routes, PVC, Secret
│   └── overlays/<S4_OVERLAY>/     # S3 route host + credentials patches (default lab)
├── logging/
│   ├── operator/base/             # Cluster Logging Operator (Subscription)
│   ├── loki-operator/base/        # Loki Operator
│   ├── loki-instance/
│   │   ├── base/                  # LokiStack + placeholder S3 Secret/CA
│   │   └── overlays/
│   │       ├── s3/                # External / S4-backed S3 patches
│   │       └── odf/               # ObjectBucketClaim + secret-sync Job
│   ├── instance/base/             # ClusterLogForwarder + collector RBAC
│   ├── coo/base/                  # Cluster Observability Operator + Logging UIPlugin
│   └── argoCD/                    # Child Argo CD Applications + AppProject
└── gitops/
    ├── app-of-apps/               # Parent AppProject + logging-apps Application
    ├── applicationset/            # Optional multi-overlay ApplicationSet
    ├── git-repository-secret.yaml
    ├── git-configure-lib.sh
    └── collect-git-ca.sh
```

**Typical lab order (with S4):** configure overlays → `./deploy-s4.sh` → refresh CA (`S4_DEPLOYED_ON_CLUSTER=true`) → deploy logging.

Apply order for logging (Kustomize or Argo sync waves):

1. Logging operator + Loki operator  
2. LokiStack instance (storage overlay)  
3. ClusterLogForwarder  
4. COO + Logging UIPlugin  

S4 is **not** managed by Argo CD in this repo; deploy it with `./deploy-s4.sh` (or `oc apply -k s4/overlays/<name>`).

---

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| OpenShift | 4.14+ recommended (Logging / Loki operator channels `stable-6.x`) |
| CLI | `oc` (uses embedded kustomize), `openssl`, `python3`, `bash` |
| Block storage | A `StorageClass` for Loki PVCs (e.g. `gp3-csi`, `thin-csi`, `ocs-storagecluster-ceph-rbd`) |
| Object storage | In-repo S4, external S3, **or** ODF with NooBaa MCG |
| S4 path only | Default `StorageClass` for the `s4-data` PVC; outbound pull of `quay.io/rh-aiservices-bu/s4:latest` |
| GitOps path only | OpenShift GitOps operator (`openshift-gitops`) already installed, or install it yourself before applying App-of-Apps |
| Infra nodes (optional) | Nodes labeled/tainted for Loki placement (see [Loki node placement](#loki-node-placement)) |

Align Subscription channels with your cluster before the first apply:

```bash
oc get packagemanifest cluster-logging loki-operator cluster-observability-operator \
  -n openshift-marketplace
```

Edit if needed:

- `logging/operator/base/subscription.yaml`
- `logging/loki-operator/base/subscription.yaml`
- `logging/coo/base/coo-operator.yaml`

Cluster access:

```bash
oc login --server=<api-url> --token=<token>
oc config view --raw > "$HOME/ocpkubeconfig"
export KUBECONFIG="$HOME/ocpkubeconfig"
```

---

## Storage configuration guide

LokiStack always needs **S3-compatible** object storage. Choose one path.

### Compare backends

| | **In-repo S4** | **External S3** | **ODF (NooBaa)** |
|--|----------------|-----------------|------------------|
| Bucket | `./deploy-s4.sh` creates it | You create externally | `ObjectBucketClaim` provisions it |
| Credentials | `S4_*` in HEADER | `LOKI_S3_*` in HEADER | OBC → Job/script maps to Loki format |
| Endpoint | S4 API Route (`S4_API_HOST`) | Your S3 HTTPS URL | Cluster-internal NooBaa S3 |
| TLS CA | Fetched after S4 is up (`S4_DEPLOYED_ON_CLUSTER`) | `FETCH_S3_CA` / `S3_CA_FILE` | `openshift-service-ca.crt` |
| Loki overlay | `overlays/s3` | `overlays/s3` | `overlays/odf` |
| Extra ops | Deploy `s4/` first | IAM + bucket first | ODF must already be installed |

### In-repo S4 (recommended for labs)

[S4](https://github.com/rh-aiservices-bu/s4) is packaged under `s4/` as Kustomize. It exposes:

| Route | Port | Purpose |
|-------|------|---------|
| `s4` (UI) | 5000 | Web UI + REST API (`https://<ui-host>/api`) used by `deploy-s4.sh` to create buckets |
| `s4-api` (S3) | 7480 | S3 API hostname Loki uses (`S4_API_HOST`) |

**Important:** Loki’s endpoint is the **S3 Route** (`s4-api` → `S4_API_HOST`), not the UI Route host.

#### 1. Edit HEADER for S4 + Loki

```bash
# In configure-overlays.sh HEADER:
STORAGE_BACKEND="s3"
OVERLAY="s3"
S4_ENABLED=true
S4_DEPLOYED_ON_CLUSTER=false
S4_OVERLAY="lab"
S4_API_HOST="s3.s4.apps.<cluster-domain>"   # must match apps domain / DNS
S4_AWS_ACCESS_KEY_ID="s4admin"
S4_AWS_SECRET_ACCESS_KEY="s4secret"
S4_UI_USERNAME="admin"
S4_UI_PASSWORD="changeme"                   # change before deploy
S4_BUCKET_NAME="loggingstack"
LOKI_STORAGE_CLASS="gp3-csi"                # existing block StorageClass
GIT_REPO_URL="https://github.com/<org>/deploy-gitops-logging.git"
```

When `S4_ENABLED=true`, the script writes `s4/overlays/<S4_OVERLAY>/` and syncs Loki S3 access key / secret / endpoint / bucket from the `S4_*` values.

```bash
./configure-overlays.sh
```

#### 2. Deploy S4 and create the bucket

```bash
./deploy-s4.sh
```

What `deploy-s4.sh` does:

1. Creates namespace `s4` (if missing)
2. Applies `s4/overlays/<S4_OVERLAY>` with `oc apply -k`
3. Restarts Deployment `s4` and waits for rollout
4. Reads UI credentials from Secret `s4-credentials`
5. Waits for UI Route `s4` and REST API readiness
6. Logs into the [S4 REST API](https://github.com/rh-aiservices-bu/s4/tree/main/docs/api) and creates bucket `S4_BUCKET_NAME` (HTTP 409 = already exists)

Manual alternative (no bucket create):

```bash
oc create namespace s4 --dry-run=client -o yaml | oc apply -f -
oc apply -n s4 -k s4/overlays/lab
oc rollout status deployment/s4 -n s4
```

#### 3. Refresh Loki TLS CA from the live S4 route

```bash
# HEADER:
S4_DEPLOYED_ON_CLUSTER=true
# Optional: leave S4_API_HOST as-is; script prefers the live Route host when oc+kubeconfig work
./configure-overlays.sh
```

This updates `logging/loki-instance/overlays/<OVERLAY>/loki-s3-ca-bundle-patch.yaml` from the S4 API TLS chain (issuer/CA preferred).

#### 4. Deploy logging

Continue with [Deploy with Kustomize only](#deploy-with-kustomize-only) or [Deploy with OpenShift GitOps](#deploy-with-openshift-gitops-argo-cd). Use overlay path `logging/loki-instance/overlays/s3` (or your `OVERLAY` name).

#### Use a different S4 overlay name

Set `S4_OVERLAY=prod` in the HEADER and run `./configure-overlays.sh`. If `s4/overlays/prod` is missing, it is seeded from `s4/overlays/lab`, then filled with your `S4_*` values. Deploy with the same HEADER via `./deploy-s4.sh`.

### External S3

1. Create a bucket (example name: `loggingstack`).
2. Create an IAM user/policy (or equivalent) with `s3:ListBucket`, `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, and tagging permissions on that bucket.
3. Create an access key pair.
4. Edit the HEADER in `configure-overlays.sh`, then run the script:

```bash
# HEADER examples (edit in configure-overlays.sh):
#   STORAGE_BACKEND="s3"
#   OVERLAY="s3"
#   S4_ENABLED=false
#   LOKI_S3_ENDPOINT="https://s3.apps.example.com"
#   LOKI_S3_BUCKET="loggingstack"
#   LOKI_S3_ACCESS_KEY_ID="<access-key>"
#   LOKI_S3_ACCESS_KEY_SECRET="<secret-key>"
#   LOKI_STORAGE_CLASS="gp3-csi"
#   FETCH_S3_CA=true
#   GIT_REPO_URL="https://github.com/<org>/deploy-gitops-logging.git"
./configure-overlays.sh
```

`FETCH_S3_CA=true` pulls the issuer/CA from `https://<LOKI_S3_ENDPOINT host>:443` into `loki-s3-ca-bundle-patch.yaml`. Set `S3_CA_FILE=/path/to/ca.pem` instead of a live fetch when needed.

5. Confirm StorageClass exists: `oc get storageclass`.

### ODF (ObjectBucketClaim / NooBaa)

1. Ensure OpenShift Data Foundation is installed and NooBaa is healthy:

```bash
oc get storageclass | grep -E 'noobaa|openshift-storage'
oc get pods -n openshift-storage
```

2. Edit the HEADER for ODF (block SC for Loki PVCs is usually Ceph RBD), then run:

```bash
# HEADER examples (edit in configure-overlays.sh):
#   STORAGE_BACKEND="odf"
#   OVERLAY="odf"
#   S4_ENABLED=false
#   ODF_STORAGE_CLASS="openshift-storage.noobaa.io"
#   LOKI_STORAGE_CLASS="ocs-storagecluster-ceph-rbd"
#   GIT_REPO_URL="https://github.com/<org>/deploy-gitops-logging.git"
./configure-overlays.sh
```

3. After apply, the overlay’s **Job** `loki-odf-secret-sync` waits for the OBC to be `Bound`, then creates Secret `logging-loki-s3` in Loki’s expected key format.

For Kustomize-only (no Argo hooks), run the helper after the OBC is Bound:

```bash
./scripts/sync-odf-loki-secret.sh
```

---

## Script usage

`configure-overlays.sh` takes **no CLI parameters**. Edit the **HEADER** at the top of the script, then run:

```bash
./configure-overlays.sh
```

The script is idempotent: it seeds missing overlay directories from the `s3` or `odf` template, rewrites patch YAML, and updates Argo CD `repoURL` / `targetRevision` / Loki instance `path`.

### HEADER variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `STORAGE_BACKEND` | `s3` or `odf` | `s3` |
| `OVERLAY` | Overlay directory under `logging/loki-instance/overlays/` | `s3` |
| `S4_ENABLED` | Write `s4/overlays/<S4_OVERLAY>` and sync Loki S3 from `S4_*` | `true` |
| `S4_DEPLOYED_ON_CLUSTER` | After S4 is up, fetch Loki TLS CA from S4 API host | `false` |
| `S4_OVERLAY` | Overlay under `s4/overlays/` (seeded from `lab`) | `lab` |
| `S4_NAMESPACE` | S4 namespace | `s4` |
| `S4_API_ROUTE_NAME` | OpenShift Route name for S3 API | `s4-api` |
| `S4_API_HOST` | S3 Route hostname (Loki endpoint host) | `s3.s4.apps.example.com` |
| `S4_AWS_ACCESS_KEY_ID` / `S4_AWS_SECRET_ACCESS_KEY` | S4 / Loki S3 credentials | `s4admin` / `s4secret` |
| `S4_UI_USERNAME` / `S4_UI_PASSWORD` | S4 UI / REST login | `admin` / `changeme` |
| `S4_BUCKET_NAME` | Bucket created by `./deploy-s4.sh` | `loggingstack` |
| `LOKI_S3_ACCESS_KEY_ID` | S3 access key (overwritten from S4 when `S4_ENABLED=true`) | placeholder |
| `LOKI_S3_ACCESS_KEY_SECRET` | S3 secret key (overwritten from S4 when enabled) | placeholder |
| `LOKI_S3_BUCKET` | Bucket name (overwritten from `S4_BUCKET_NAME` when enabled) | `loggingstack` |
| `LOKI_S3_ENDPOINT` | S3 API URL (overwritten from `https://S4_API_HOST` when enabled) | `https://s3.example.com` |
| `LOKI_S3_REGION` | Optional region key | empty |
| `LOKI_S3_FORCE_PATH_STYLE` | Path-style addressing | `true` |
| `LOKI_S3_SECRET_NAME` | LokiStack secret name | `logging-loki-s3` |
| `LOKI_S3_SECRET_TYPE` | LokiStack secret type | `s3` |
| `LOKI_TLS_CA_NAME` | S3 TLS CA ConfigMap name | `loki-s3-ca-bundle` |
| `FETCH_S3_CA` | Fetch/refresh S3 TLS CA into the overlay patch | `false` |
| `S3_CA_FILE` | Optional PEM path (used when CA fetch is enabled) | empty |
| `ODF_OBC_NAME` | ObjectBucketClaim name | `logging-loki-obc` |
| `ODF_GENERATE_BUCKET_NAME` | OBC `generateBucketName` | `logging-loki` |
| `ODF_STORAGE_CLASS` | OBC StorageClass | `openshift-storage.noobaa.io` |
| `LOKI_TLS_CA_NAME_ODF` | TLS CA ConfigMap for ODF/NooBaa | `openshift-service-ca.crt` |
| `LOKI_STORAGE_CLASS` | Block StorageClass for Loki PVCs | `gp3-csi` |
| `LOKI_SCHEMA_EFFECTIVE_DATE` | Loki schema effective date | `2026-06-15` |
| `LOKI_SCHEMA_VERSION` | Loki schema version | `v13` |
| `LOKI_SIZE` | LokiStack size | `1x.pico` |
| `LOKI_RETENTION_DAYS` | Log retention (days) | `14` |
| `LOKI_NODE_SELECTOR_KEY` / `LOKI_NODE_SELECTOR_VALUE` | Infra nodeSelector | `node-role.kubernetes.io/infra` / empty |
| `LOKI_TOLERATION_KEY` / `LOKI_TOLERATION_VALUE` / `LOKI_TOLERATION_EFFECT` | Infra toleration | infra key, empty value, `NoSchedule` |
| `KUBECONFIG_PATH` | Optional kubeconfig path | `$HOME/ocpkubeconfig` |
| `GIT_PROTOCOL` | `https` or `ssh` | `https` |
| `GIT_REPO_URL` | Argo CD repo URL | example placeholder |
| `GIT_TARGET_REVISION` | Git revision | `HEAD` |
| `GIT_SSH_USER` / `GIT_SSH_HOST` / `GIT_SSH_PORT` / `GIT_REPO_PATH` | SSH Git settings | `git` / empty / empty / empty |
| `GIT_SSH_PRIVATE_KEY_FILE` | Deploy key path for Argo Secret | `$HOME/.ssh/id_ed25519` |
| `GIT_SSH_INSECURE_IGNORE_HOST_KEY` | Argo SSH host-key flag | `true` |
| `GIT_TLS_INSECURE` | Argo HTTPS insecure flag | `true` |
| `GIT_USERNAME` / `GIT_PASSWORD` | Optional HTTPS credentials | empty |
| `GIT_CA_FILE` | Optional Git CA PEM path (from `collect-git-ca.sh`) | `gitops/git-ca.crt` |

### Examples

**In-repo S4 + Loki `s3` overlay:**

```bash
# HEADER: S4_ENABLED=true, S4_OVERLAY=lab, S4_API_HOST=..., S4_BUCKET_NAME=loggingstack,
#         STORAGE_BACKEND=s3, OVERLAY=s3, LOKI_STORAGE_CLASS=thin-csi, GIT_REPO_URL=...
./configure-overlays.sh
./deploy-s4.sh
# HEADER: S4_DEPLOYED_ON_CLUSTER=true
./configure-overlays.sh
```

**External S3 lab overlay named `lab`** (auto-seeded from `overlays/s3`):

```bash
# In configure-overlays.sh HEADER:
#   STORAGE_BACKEND="s3"
#   OVERLAY="lab"
#   S4_ENABLED=false
#   LOKI_S3_ENDPOINT="https://s3.lab.example.com"
#   LOKI_S3_BUCKET="loggingstack"
#   LOKI_S3_ACCESS_KEY_ID="..."
#   LOKI_S3_ACCESS_KEY_SECRET="..."
#   LOKI_STORAGE_CLASS="thin-csi"
#   FETCH_S3_CA=true
#   GIT_REPO_URL="https://git.example.com/org/deploy-gitops-logging.git"
./configure-overlays.sh
```

**ODF:**

```bash
# HEADER:
#   STORAGE_BACKEND="odf"
#   OVERLAY="odf"
#   LOKI_STORAGE_CLASS="ocs-storagecluster-ceph-rbd"
#   GIT_REPO_URL="https://git.example.com/org/deploy-gitops-logging.git"
./configure-overlays.sh
```

**HTTPS Git with self-signed CA for Argo CD:**

```bash
./gitops/collect-git-ca.sh https://git.example.com/org/deploy-gitops-logging.git
# HEADER: GIT_PROTOCOL="https", GIT_REPO_URL="https://git.example.com/org/deploy-gitops-logging.git"
#         GIT_TLS_INSECURE="false", GIT_CA_FILE="gitops/git-ca.crt"
./configure-overlays.sh
```

---

## Deploy with Kustomize only

Copy-paste path (operators → Loki → collector → COO).

### 1. Configure overlays (and S4 if used)

```bash
cd /path/to/deploy-gitops-logging
# Edit HEADER in configure-overlays.sh (S4 / external S3 / ODF — see Storage guide)
./configure-overlays.sh

# If S4_ENABLED=true:
./deploy-s4.sh
# Then set S4_DEPLOYED_ON_CLUSTER=true in the HEADER and re-run:
./configure-overlays.sh
```

### 2. Apply operators

```bash
oc apply -k logging/operator/base
oc apply -k logging/loki-operator/base

# Wait until CSVs are Succeeded
oc get csv -n openshift-logging
oc get csv -n openshift-operators-redhat
```

### 3. Apply LokiStack (storage overlay)

**S3:**

```bash
oc apply -k logging/loki-instance/overlays/s3
oc get lokistack logging-loki -n openshift-logging -w
```

**ODF:**

```bash
oc apply -k logging/loki-instance/overlays/odf
oc get objectbucketclaim -n openshift-logging -w
# After Bound, if the Job has not finished yet:
./scripts/sync-odf-loki-secret.sh
oc get lokistack logging-loki -n openshift-logging -w
```

### 4. Apply ClusterLogForwarder

```bash
oc apply -k logging/instance/base
oc get clusterlogforwarder -n openshift-logging
```

### 5. Apply Cluster Observability Operator (console logs UI)

```bash
oc apply -k logging/coo/base
oc get uiplugin logging
```

---

## Deploy with OpenShift GitOps (Argo CD)

Assumes OpenShift GitOps is installed (`openshift-gitops` namespace) and you can push this repo to a Git remote Argo CD can reach.

### 1. Configure overlays + Git settings (+ S4 if used)

```bash
# Edit HEADER in configure-overlays.sh, including:
#   STORAGE_BACKEND, OVERLAY, S4_* (or LOKI_S3_* / ODF_*), LOKI_STORAGE_CLASS
#   GIT_REPO_URL, GIT_TARGET_REVISION, GIT_PROTOCOL / GIT_TLS_* or GIT_SSH_*
./configure-overlays.sh

# If using in-repo S4 (before committing Loki CA):
./deploy-s4.sh
# HEADER: S4_DEPLOYED_ON_CLUSTER=true
./configure-overlays.sh
```

### 2. Commit and push

```bash
git add -A
git status
git commit -m "Configure logging overlays for <cluster>"
git push
```

Do **not** commit real production credentials if your Git remote is broadly shared — prefer sealed secrets / External Secrets, or keep secret patches out of the default branch.

### 3. Register the Git repository with Argo CD

```bash
oc apply -f gitops/git-repository-secret.yaml
# Optional self-signed Git CA:
# ./gitops/collect-git-ca.sh <git-host>
# then merge into argocd-tls-certs-cm (see OpenShift GitOps docs)
```

### 4. Apply App-of-Apps

```bash
oc apply -k gitops/app-of-apps
```

This creates:

- AppProject `cluster-config`
- Application `logging-apps` → syncs `logging/argoCD`

Argo CD then creates child Applications:

| Application | Path |
|-------------|------|
| `logging-operator` | `logging/operator/base` |
| `loki-operator` | `logging/loki-operator/base` |
| `loki-instance` | `logging/loki-instance/overlays/<OVERLAY>` |
| `logging-instance` | `logging/instance/base` |
| `coo` | `logging/coo/base` |

### 5. Optional: ApplicationSet

For multi-cluster or multi-overlay generation:

```bash
# Edit generators in gitops/applicationset/logging-applicationset.yaml
oc apply -f gitops/applicationset/logging-applicationset.yaml
```

### 6. Watch sync

```bash
oc get applications -n openshift-gitops \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

---

## Verification

```bash
# S4 (if used)
oc get pods,route,pvc -n s4
oc get route s4-api -n s4 -o jsonpath='{.spec.host}{"\n"}'

# Operators
oc get csv -n openshift-logging
oc get csv -n openshift-operators-redhat
oc get csv -n openshift-cluster-observability-operator

# LokiStack
oc get lokistack logging-loki -n openshift-logging
oc get pods -n openshift-logging -l app.kubernetes.io/name=lokistack

# Log collector (ClusterLogForwarder)
oc get clusterlogforwarder instance -n openshift-logging
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector

# ODF only
oc get objectbucketclaim -n openshift-logging
oc get job loki-odf-secret-sync -n openshift-logging
oc get secret logging-loki-s3 -n openshift-logging

# Ingestion smoke check (OpenShift console → Observe → Logs, or LogQL via gateway)
oc get route -n openshift-logging | grep -i loki || true
```

Expect LokiStack `status.conditions` Ready, collector DaemonSet pods Running on nodes, and application/infrastructure logs appearing in the Logging UIPlugin within a few minutes.

---

## Loki node placement

Default overlays schedule Loki components on infra nodes:

- `nodeSelector`: `node-role.kubernetes.io/infra=`
- `toleration`: `node-role.kubernetes.io/infra:NoSchedule` (`Exists`)

```bash
NODE=<node-name>
oc label node "$NODE" node-role.kubernetes.io/infra=
oc adm taint node "$NODE" node-role.kubernetes.io/infra:NoSchedule

oc get nodes -l node-role.kubernetes.io/infra \
  -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

Change `LOKI_NODE_SELECTOR_*` / `LOKI_TOLERATION_*` in the HEADER, re-run `./configure-overlays.sh`, then re-apply / re-sync.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Loki pods `Pending` | Missing infra label/taint or wrong StorageClass | Label/taint nodes; set `LOKI_STORAGE_CLASS` in the HEADER to an existing SC |
| `invalid document separator` in CA ConfigMap | PEM not indented under `\|` | Set `S4_DEPLOYED_ON_CLUSTER=true` or `FETCH_S3_CA=true`, then re-run configure |
| S4 login `401 Unauthorized` | Pod still on old Secret / wrong UI creds | Re-run `./deploy-s4.sh` (rollout restart + creds from Secret) |
| S4 PVC pending | No default StorageClass | Set a StorageClass on `s4/base/s4-pvc.yaml` or make one default |
| ODF Loki secret missing | OBC not Bound / Job failed | `oc describe obc`, `oc logs job/loki-odf-secret-sync`, or `./scripts/sync-odf-loki-secret.sh` |
| Argo `x509: unknown authority` | Self-signed Git TLS | `./gitops/collect-git-ca.sh` and trust CA in Argo CD |
| UIPlugin not found | COO CRD not ready | Wait for COO CSV; sync option `SkipDryRunOnMissingResource` is set |
| CatalogSourcesUnhealthy | Wrong Subscription `source` | `oc get catalogsource -n openshift-marketplace` |

---

## License / scope

This project is dedicated to OpenShift Logging (plus optional in-repo [S4](https://github.com/rh-aiservices-bu/s4) for labs). It intentionally omits Keycloak, Postgres, and Ansible playbooks from the sibling `ocp-deploy-keycloak-logging` repository. Point Loki at in-repo S4, any reachable S3-compatible endpoint, or ODF NooBaa.
