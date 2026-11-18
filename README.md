# OpenShift Logging (GitOps)

Deploy **OpenShift Logging** with LokiStack using either plain Kustomize or OpenShift GitOps (Argo CD).

This repo is logging-only. For object storage you can use:

| Option | Best for | What you need |
|--------|----------|---------------|
| **In-repo [S4](https://github.com/rh-aiservices-bu/s4)** | Labs and demos | Deploy `s4/` on the cluster, then point Loki at it |
| **External S3** | Existing buckets (AWS, MinIO, Ceph, remote S4, …) | Endpoint, credentials, and a bucket you already own |
| **ODF / NooBaa** | Clusters with OpenShift Data Foundation | Working NooBaa; Loki uses an `ObjectBucketClaim` |

Configuration is done by editing the **HEADER** in [`configure-overlays.sh`](configure-overlays.sh), then running the script. There are no CLI flags.

---

## Contents

1. [Quick start (lab with S4)](#1-quick-start-lab-with-s4)
2. [Before you start](#2-before-you-start)
3. [How configuration works](#3-how-configuration-works)
4. [Choose object storage](#4-choose-object-storage)
5. [Deploy with Kustomize](#5-deploy-with-kustomize)
6. [Deploy with OpenShift GitOps](#6-deploy-with-openshift-gitops)
7. [Verify the install](#7-verify-the-install)
8. [Optional: Loki on infra nodes](#8-optional-loki-on-infra-nodes)
9. [Troubleshooting](#9-troubleshooting)
10. [Repository layout](#10-repository-layout)
11. [Appendix: HEADER variables](#11-appendix-header-variables)

---

## 1. Quick start (lab with S4)

Use this path when you want logging on a lab cluster and do not already have S3.

### Step A — Cluster login

```bash
oc login --server=<api-url> --token=<token>
oc config view --raw > "$HOME/ocpkubeconfig"
export KUBECONFIG="$HOME/ocpkubeconfig"
```

### Step B — Edit the HEADER

Open `configure-overlays.sh` and set at least:

```bash
STORAGE_BACKEND="s3"
OVERLAY="s3"
S4_ENABLED=true
S4_DEPLOYED_ON_CLUSTER=false
S4_OVERLAY="lab"
S4_API_HOST="s3.s4.apps.<your-cluster-domain>"
S4_UI_PASSWORD="changeme"          # change this
S4_BUCKET_NAME="loggingstack"
LOKI_STORAGE_CLASS="gp3-csi"       # must exist: oc get storageclass
GIT_REPO_URL="https://github.com/<org>/deploy-gitops-logging.git"
```

Then generate the overlay patches:

```bash
./configure-overlays.sh
```

### Step C — Deploy S4 and create the bucket

```bash
./deploy-s4.sh
```

### Step D — Refresh Loki’s TLS CA

S4 is up now. Tell the configure script to pull the CA from the live S3 route:

```bash
# In the HEADER, set:
S4_DEPLOYED_ON_CLUSTER=true
./configure-overlays.sh
```

### Step E — Install logging

**Kustomize:**

```bash
oc apply -k logging/operator/base
oc apply -k logging/loki-operator/base
oc apply -k logging/loki-instance/overlays/s3
oc apply -k logging/instance/base
oc apply -k logging/coo/base
```

**Or GitOps:** commit/push, then:

```bash
oc apply -f gitops/git-repository-secret.yaml
oc apply -k gitops/app-of-apps
```

Jump to [Verify the install](#7-verify-the-install) when you are done.

> **Tip:** Loki talks to the **S3 API route** (`s4-api` / `S4_API_HOST`), not the S4 web UI route.

---

## 2. Before you start

| Need | Details |
|------|---------|
| OpenShift | 4.14+ recommended; Logging/Loki channels around `stable-6.x` |
| Tools | `oc`, `bash`, `python3`, `openssl` (`curl` for `deploy-s4.sh`) |
| Block storage | A StorageClass for Loki PVCs (`oc get storageclass`) |
| Object storage | S4 **or** external S3 **or** ODF/NooBaa |
| GitOps path | OpenShift GitOps already installed (`openshift-gitops`) |
| S4 path | Cluster can pull `quay.io/rh-aiservices-bu/s4:latest`; PVC needs a StorageClass |

Check operator packages and adjust Subscription channels if needed:

```bash
oc get packagemanifest cluster-logging loki-operator cluster-observability-operator \
  -n openshift-marketplace
```

Files to edit if your channel differs:

- `logging/operator/base/subscription.yaml`
- `logging/loki-operator/base/subscription.yaml`
- `logging/coo/base/coo-operator.yaml`

---

## 3. How configuration works

All environment-specific values live in the **HEADER** at the top of `configure-overlays.sh`.

```bash
# 1. Edit HEADER values
# 2. Run (no arguments):
./configure-overlays.sh
```

The script is safe to re-run. It will:

- Create a missing Loki overlay by copying from `overlays/s3` or `overlays/odf`
- Create a missing S4 overlay by copying from `s4/overlays/lab` (when S4 is enabled)
- Rewrite patch YAML (storage, placement, credentials, CA)
- Update Argo CD `repoURL`, revision, and the Loki instance path

If you pass any arguments, the script exits and asks you to use the HEADER instead.

Full variable list: [Appendix](#11-appendix-header-variables).

---

## 4. Choose object storage

Loki always needs S3-compatible storage. Pick **one** option below.

### Option A — In-repo S4 (labs)

S4 ships in this repo under `s4/`. Two routes matter:

| Route | Role |
|-------|------|
| `s4` | Web UI and REST API (`/api`) — used to create the bucket |
| `s4-api` | S3 API — **this** is what Loki uses (`S4_API_HOST`) |

**Flow**

1. Set `S4_ENABLED=true` and the other `S4_*` values in the HEADER → `./configure-overlays.sh`
2. `./deploy-s4.sh` — applies the overlay, waits for rollout, creates `S4_BUCKET_NAME`
3. Set `S4_DEPLOYED_ON_CLUSTER=true` → `./configure-overlays.sh` again (CA for Loki)
4. Deploy logging ([Kustomize](#5-deploy-with-kustomize) or [GitOps](#6-deploy-with-openshift-gitops))

When S4 is enabled, Loki’s access key, secret, endpoint, and bucket are taken from the `S4_*` values so they cannot drift.

**New S4 overlay name:** set `S4_OVERLAY=prod`, run configure (seeds from `lab` if needed), then `./deploy-s4.sh`.

**Manual apply** (no automatic bucket create):

```bash
oc create namespace s4 --dry-run=client -o yaml | oc apply -f -
oc apply -n s4 -k s4/overlays/lab
oc rollout status deployment/s4 -n s4
```

### Option B — External S3

1. Create a bucket and credentials with list/get/put/delete (and tagging) permissions.
2. In the HEADER:

```bash
STORAGE_BACKEND="s3"
OVERLAY="s3"
S4_ENABLED=false
LOKI_S3_ENDPOINT="https://s3.example.com"
LOKI_S3_BUCKET="loggingstack"
LOKI_S3_ACCESS_KEY_ID="<key>"
LOKI_S3_ACCESS_KEY_SECRET="<secret>"
LOKI_STORAGE_CLASS="gp3-csi"
FETCH_S3_CA=true          # or set S3_CA_FILE=/path/to/ca.pem
```

3. Run `./configure-overlays.sh`, then deploy logging.

### Option C — ODF / NooBaa

1. Confirm ODF/NooBaa is healthy:

```bash
oc get storageclass | grep -E 'noobaa|openshift-storage'
oc get pods -n openshift-storage
```

2. In the HEADER:

```bash
STORAGE_BACKEND="odf"
OVERLAY="odf"
S4_ENABLED=false
ODF_STORAGE_CLASS="openshift-storage.noobaa.io"
LOKI_STORAGE_CLASS="ocs-storagecluster-ceph-rbd"
```

3. Run `./configure-overlays.sh`, then deploy logging with the `odf` overlay.

After apply, Job `loki-odf-secret-sync` waits for the `ObjectBucketClaim` and builds Secret `logging-loki-s3`. For Kustomize-only installs, you can also run:

```bash
./scripts/sync-odf-loki-secret.sh
```

---

## 5. Deploy with Kustomize

Do storage setup first ([§4](#4-choose-object-storage)), then apply in this order.

### Operators

```bash
oc apply -k logging/operator/base
oc apply -k logging/loki-operator/base

oc get csv -n openshift-logging
oc get csv -n openshift-operators-redhat
```

Wait until CSVs show `Succeeded`.

### LokiStack

```bash
# S3 or S4-backed:
oc apply -k logging/loki-instance/overlays/s3

# Or ODF:
oc apply -k logging/loki-instance/overlays/odf
# If needed after OBC is Bound:
./scripts/sync-odf-loki-secret.sh

oc get lokistack logging-loki -n openshift-logging -w
```

Use your own `OVERLAY` name if you seeded one (for example `overlays/lab`).

### Collector and console UI

```bash
oc apply -k logging/instance/base
oc apply -k logging/coo/base

oc get clusterlogforwarder -n openshift-logging
oc get uiplugin logging
```

---

## 6. Deploy with OpenShift GitOps

Assumes OpenShift GitOps is installed and this repo is reachable by Argo CD.

S4 (if you use it) is **not** an Argo app — deploy it with `./deploy-s4.sh` before syncing Loki.

### 1. Configure and push

```bash
# Edit HEADER (storage + GIT_REPO_URL / GIT_TARGET_REVISION / protocol)
./configure-overlays.sh
# If S4: ./deploy-s4.sh → S4_DEPLOYED_ON_CLUSTER=true → ./configure-overlays.sh again

git add -A
git commit -m "Configure logging overlays for <cluster>"
git push
```

Avoid committing production secrets to a shared remote. Prefer sealed/external secrets when that matters.

### 2. Register the Git repo with Argo CD

```bash
oc apply -f gitops/git-repository-secret.yaml
```

Self-signed Git HTTPS:

```bash
./gitops/collect-git-ca.sh https://git.example.com/org/deploy-gitops-logging.git
# HEADER: GIT_TLS_INSECURE="false", GIT_CA_FILE="gitops/git-ca.crt"
./configure-overlays.sh
# Trust the CA in Argo CD (argocd-tls-certs-cm) per OpenShift GitOps docs
```

### 3. Apply the App-of-Apps

```bash
oc apply -k gitops/app-of-apps
```

That creates AppProject `cluster-config` and Application `logging-apps`, which syncs `logging/argoCD` and these child apps:

| Application | Path |
|-------------|------|
| `logging-operator` | `logging/operator/base` |
| `loki-operator` | `logging/loki-operator/base` |
| `loki-instance` | `logging/loki-instance/overlays/<OVERLAY>` |
| `logging-instance` | `logging/instance/base` |
| `coo` | `logging/coo/base` |

### 4. Watch sync (optional ApplicationSet)

```bash
oc get applications -n openshift-gitops \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

For multi-cluster / multi-overlay generation, edit and apply:

```bash
oc apply -f gitops/applicationset/logging-applicationset.yaml
```

---

## 7. Verify the install

```bash
# S4 (if used)
oc get pods,route,pvc -n s4
oc get route s4-api -n s4 -o jsonpath='{.spec.host}{"\n"}'

# Operators
oc get csv -n openshift-logging
oc get csv -n openshift-operators-redhat
oc get csv -n openshift-cluster-observability-operator

# Loki + collectors
oc get lokistack logging-loki -n openshift-logging
oc get pods -n openshift-logging
oc get clusterlogforwarder instance -n openshift-logging

# ODF (if used)
oc get objectbucketclaim -n openshift-logging
oc get job loki-odf-secret-sync -n openshift-logging
```

You want LokiStack Ready, collector pods Running, and logs visible under **Observe → Logs** in the console within a few minutes.

---

## 8. Optional: Loki on infra nodes

Overlays default to infra placement:

- Label: `node-role.kubernetes.io/infra=`
- Taint toleration: `node-role.kubernetes.io/infra:NoSchedule` (operator `Exists`)

```bash
NODE=<node-name>
oc label node "$NODE" node-role.kubernetes.io/infra=
oc adm taint node "$NODE" node-role.kubernetes.io/infra:NoSchedule
```

To change placement, edit `LOKI_NODE_SELECTOR_*` / `LOKI_TOLERATION_*` in the HEADER, re-run `./configure-overlays.sh`, then re-apply or re-sync.

---

## 9. Troubleshooting

| Symptom | What to try |
|---------|-------------|
| Loki pods `Pending` | Label/taint infra nodes; set `LOKI_STORAGE_CLASS` to a StorageClass that exists |
| Bad CA / `invalid document separator` | Re-run configure with `S4_DEPLOYED_ON_CLUSTER=true` or `FETCH_S3_CA=true` (PEM must stay indented under `\|`) |
| S4 login `401` | Re-run `./deploy-s4.sh` so the pod reloads Secret credentials |
| S4 PVC pending | Give `s4/base/s4-pvc.yaml` a StorageClass, or make one default |
| ODF secret missing | Wait for OBC `Bound`; check Job logs or run `./scripts/sync-odf-loki-secret.sh` |
| Argo `x509: unknown authority` | Collect Git CA with `./gitops/collect-git-ca.sh` and trust it in Argo CD |
| UIPlugin not found | Wait for COO CSV / CRD; dry-run skip is already set on the app |
| `CatalogSourcesUnhealthy` | Fix Subscription `source` against `oc get catalogsource -n openshift-marketplace` |

---

## 10. Repository layout

```text
configure-overlays.sh     Edit HEADER here, then run
deploy-s4.sh              Deploy S4 + create Loki bucket
s4/                       In-repo S3-compatible storage (optional)
logging/
  operator/               Cluster Logging Operator
  loki-operator/          Loki Operator
  loki-instance/          LokiStack + s3 | odf overlays
  instance/               ClusterLogForwarder + RBAC
  coo/                    Observability operator + Logging UI
  argoCD/                 Child Argo CD Applications
gitops/
  app-of-apps/            Parent App-of-Apps
  applicationset/         Optional ApplicationSet
scripts/                  ODF secret helper
```

**Logging apply order:** operators → LokiStack → ClusterLogForwarder → COO.

---

## 11. Appendix: HEADER variables

Edit these in `configure-overlays.sh`. Defaults match the script HEADER.

### Storage choice

| Variable | Meaning | Default |
|----------|---------|---------|
| `STORAGE_BACKEND` | `s3` or `odf` | `s3` |
| `OVERLAY` | Directory under `logging/loki-instance/overlays/` | `s3` |

### S4 (in-repo)

| Variable | Meaning | Default |
|----------|---------|---------|
| `S4_ENABLED` | Manage `s4/overlays/…` and sync Loki S3 from `S4_*` | `true` |
| `S4_DEPLOYED_ON_CLUSTER` | Fetch Loki CA from live S4 after deploy | `false` |
| `S4_OVERLAY` | `s4/overlays/<name>` (seeded from `lab`) | `lab` |
| `S4_NAMESPACE` | Namespace | `s4` |
| `S4_API_ROUTE_NAME` | S3 Route object name | `s4-api` |
| `S4_API_HOST` | S3 Route hostname (Loki endpoint host) | `s3.s4.apps.example.com` |
| `S4_AWS_ACCESS_KEY_ID` / `S4_AWS_SECRET_ACCESS_KEY` | S3 credentials | `s4admin` / `s4secret` |
| `S4_UI_USERNAME` / `S4_UI_PASSWORD` | UI / REST login | `admin` / `changeme` |
| `S4_BUCKET_NAME` | Bucket created by `deploy-s4.sh` | `loggingstack` |

### Loki S3 (external or synced from S4)

| Variable | Meaning | Default |
|----------|---------|---------|
| `LOKI_S3_ACCESS_KEY_ID` / `LOKI_S3_ACCESS_KEY_SECRET` | Credentials (overwritten if S4 enabled) | placeholders |
| `LOKI_S3_BUCKET` / `LOKI_S3_ENDPOINT` | Bucket and URL (overwritten if S4 enabled) | `loggingstack` / example URL |
| `LOKI_S3_REGION` | Optional | empty |
| `LOKI_S3_FORCE_PATH_STYLE` | Path-style addressing | `true` |
| `LOKI_S3_SECRET_NAME` / `LOKI_S3_SECRET_TYPE` | Secret referenced by LokiStack | `logging-loki-s3` / `s3` |
| `LOKI_TLS_CA_NAME` | CA ConfigMap for S3 TLS | `loki-s3-ca-bundle` |
| `FETCH_S3_CA` | Fetch CA from endpoint | `false` |
| `S3_CA_FILE` | PEM file instead of live fetch | empty |

### ODF

| Variable | Meaning | Default |
|----------|---------|---------|
| `ODF_OBC_NAME` | ObjectBucketClaim name | `logging-loki-obc` |
| `ODF_GENERATE_BUCKET_NAME` | Bucket name prefix | `logging-loki` |
| `ODF_STORAGE_CLASS` | NooBaa StorageClass | `openshift-storage.noobaa.io` |
| `LOKI_TLS_CA_NAME_ODF` | CA ConfigMap for NooBaa TLS | `openshift-service-ca.crt` |

### LokiStack size and placement

| Variable | Meaning | Default |
|----------|---------|---------|
| `LOKI_STORAGE_CLASS` | Block StorageClass for Loki PVCs | `gp3-csi` |
| `LOKI_SCHEMA_EFFECTIVE_DATE` / `LOKI_SCHEMA_VERSION` | Schema | `2026-06-15` / `v13` |
| `LOKI_SIZE` | Stack size | `1x.pico` |
| `LOKI_RETENTION_DAYS` | Retention | `14` |
| `LOKI_NODE_SELECTOR_KEY` / `VALUE` | Node selector | infra / empty |
| `LOKI_TOLERATION_KEY` / `VALUE` / `EFFECT` | Toleration | infra / empty / `NoSchedule` |

### Git / Argo CD

| Variable | Meaning | Default |
|----------|---------|---------|
| `GIT_PROTOCOL` | `https` or `ssh` | `https` |
| `GIT_REPO_URL` | Repository URL | example placeholder |
| `GIT_TARGET_REVISION` | Branch / tag / SHA | `HEAD` |
| `GIT_SSH_*` | SSH user, host, port, path, key, host-key flag | see HEADER |
| `GIT_TLS_INSECURE` / `GIT_USERNAME` / `GIT_PASSWORD` | HTTPS options | `true` / empty |
| `GIT_CA_FILE` | Optional Git CA PEM | `gitops/git-ca.crt` |
| `KUBECONFIG_PATH` | kubeconfig for live Route/CA helpers | `$HOME/ocpkubeconfig` |
