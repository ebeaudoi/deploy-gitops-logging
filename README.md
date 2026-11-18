# OpenShift Logging (GitOps)

Standalone repository for deploying **OpenShift Logging** with LokiStack — no Keycloak or unrelated workloads.

Supports:

- **Pure Kustomize** (`oc apply -k`)
- **OpenShift GitOps (Argo CD)** App-of-Apps and optional **ApplicationSet**

Object storage backends:

| Backend | Overlay | When to use |
|---------|---------|-------------|
| **S3 / S4** | `logging/loki-instance/overlays/s3` | External S3-compatible bucket (AWS, MinIO, S4, Ceph RGW, …) |
| **ODF** | `logging/loki-instance/overlays/odf` | OpenShift Data Foundation NooBaa / Multicloud Object Gateway via `ObjectBucketClaim` |

---

## Index

- [Repository structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Storage configuration guide](#storage-configuration-guide)
  - [S3 / S4](#s3--s4-external-object-storage)
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
├── configure-overlays.sh          # Idempotent overlay / Argo URL updater
├── scripts/
│   └── sync-odf-loki-secret.sh    # Manual ODF → Loki secret helper
├── logging/
│   ├── operator/base/             # Cluster Logging Operator (Subscription)
│   ├── loki-operator/base/        # Loki Operator
│   ├── loki-instance/
│   │   ├── base/                  # LokiStack + placeholder S3 Secret/CA
│   │   └── overlays/
│   │       ├── s3/                # External S3/S4 patches
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

Apply order (Kustomize or Argo sync waves):

1. Logging operator + Loki operator  
2. LokiStack instance (storage overlay)  
3. ClusterLogForwarder  
4. COO + Logging UIPlugin  

---

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| OpenShift | 4.14+ recommended (Logging / Loki operator channels `stable-6.x`) |
| CLI | `oc` (uses embedded kustomize), `openssl`, `python3`, `bash` |
| Block storage | A `StorageClass` for Loki PVCs (e.g. `gp3-csi`, `thin-csi`, `ocs-storagecluster-ceph-rbd`) |
| Object storage | External S3/S4 **or** ODF with NooBaa MCG |
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

| | **S3 / S4** | **ODF (NooBaa)** |
|--|-------------|------------------|
| Bucket | You create externally | `ObjectBucketClaim` provisions it |
| Credentials | You supply access key / secret | OBC creates them; Job/script maps to Loki format |
| Endpoint | External HTTPS URL | Cluster-internal NooBaa S3 service |
| TLS CA | Often a custom CA ConfigMap (`loki-s3-ca-bundle`) | Usually `openshift-service-ca.crt` |
| Overlay | `overlays/s3` | `overlays/odf` |
| Extra ops | Create bucket + IAM policy first | ODF must already be installed |

### S3 / S4 (external object storage)

1. Create a bucket (example name: `loggingstack`).
2. Create an IAM user/policy (or equivalent) with `s3:ListBucket`, `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, and tagging permissions on that bucket.
3. Create an access key pair.
4. Edit the HEADER in `configure-overlays.sh`, then run the script:

```bash
# HEADER examples (edit in configure-overlays.sh):
#   STORAGE_BACKEND="s3"
#   OVERLAY="s3"
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
| `LOKI_S3_ACCESS_KEY_ID` | S3 access key | `CHANGE_ME_ACCESS_KEY` |
| `LOKI_S3_ACCESS_KEY_SECRET` | S3 secret key | `CHANGE_ME_SECRET_KEY` |
| `LOKI_S3_BUCKET` | Bucket name | `loggingstack` |
| `LOKI_S3_ENDPOINT` | S3 API URL | `https://s3.example.com` |
| `LOKI_S3_REGION` | Optional region key | empty |
| `LOKI_S3_FORCE_PATH_STYLE` | Path-style addressing | `true` |
| `LOKI_S3_SECRET_NAME` | LokiStack secret name | `logging-loki-s3` |
| `LOKI_S3_SECRET_TYPE` | LokiStack secret type | `s3` |
| `LOKI_TLS_CA_NAME` | S3 TLS CA ConfigMap name | `loki-s3-ca-bundle` |
| `FETCH_S3_CA` | Fetch/refresh S3 TLS CA into the overlay patch | `false` |
| `S3_CA_FILE` | Optional PEM path (used when `FETCH_S3_CA=true`) | empty |
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

**S3 lab overlay named `lab`** (auto-seeded from `overlays/s3`):

```bash
# In configure-overlays.sh HEADER:
#   STORAGE_BACKEND="s3"
#   OVERLAY="lab"
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

### 1. Configure overlays

```bash
cd /path/to/deploy-gitops-logging
# Edit HEADER in configure-overlays.sh (S3 or ODF — see Storage configuration guide)
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

### 1. Configure overlays + Git settings

```bash
# Edit HEADER in configure-overlays.sh, including:
#   STORAGE_BACKEND, OVERLAY, LOKI_S3_* (or ODF_*), LOKI_STORAGE_CLASS
#   GIT_REPO_URL, GIT_TARGET_REVISION, GIT_PROTOCOL / GIT_TLS_* or GIT_SSH_*
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
| `invalid document separator` in CA ConfigMap | PEM not indented under `\|` | Set `FETCH_S3_CA=true` (and optionally `S3_CA_FILE`) in the HEADER, then re-run |
| ODF Loki secret missing | OBC not Bound / Job failed | `oc describe obc`, `oc logs job/loki-odf-secret-sync`, or `./scripts/sync-odf-loki-secret.sh` |
| Argo `x509: unknown authority` | Self-signed Git TLS | `./gitops/collect-git-ca.sh` and trust CA in Argo CD |
| UIPlugin not found | COO CRD not ready | Wait for COO CSV; sync option `SkipDryRunOnMissingResource` is set |
| CatalogSourcesUnhealthy | Wrong Subscription `source` | `oc get catalogsource -n openshift-marketplace` |

---

## License / scope

This project is dedicated to OpenShift Logging only. It intentionally omits Keycloak, Postgres, Ansible playbooks, and in-cluster S4 packaging from the sibling `ocp-deploy-keycloak-logging` repository. Point Loki at any reachable S3-compatible endpoint or ODF NooBaa.
