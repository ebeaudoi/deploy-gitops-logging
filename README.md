# OpenShift Logging (GitOps)

Deploy **OpenShift Logging** with LokiStack using either plain Kustomize or OpenShift GitOps (Argo CD).

This repo is logging-only. For object storage you can use:

| Option | Best for | What you need |
|--------|----------|---------------|
| **In-repo [S4](https://github.com/rh-aiservices-bu/s4)** (`STORAGE_BACKEND=s4`) | Labs and demos | Deploy `s4/` on the cluster, then point Loki at it |
| **External S3** (`STORAGE_BACKEND=s3`) | Existing buckets (AWS, MinIO, Ceph, …) | Endpoint, credentials, and a bucket you already own |
| **ODF / NooBaa** (`STORAGE_BACKEND=odf`) | Clusters with OpenShift Data Foundation | Working NooBaa; Loki uses an `ObjectBucketClaim` |

Edit only the **HEADER** in [`configure-overlays.sh`](configure-overlays.sh) (a short list of required values), then run the script. No CLI flags.

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

Open `configure-overlays.sh` and set:

```bash
OVERLAY="lab"
STORAGE_BACKEND="s4"
LOKI_STORAGE_CLASS="gp3-csi"       # must exist: oc get storageclass
S4_API_HOST="s3.s4.apps.<your-cluster-domain>"
S4_ACCESS_KEY="s4admin"
S4_SECRET_KEY="s4secret"
S4_UI_PASSWORD="changeme"          # change this
S4_DEPLOYED_ON_CLUSTER=false
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
oc apply -k logging/loki-instance/overlays/lab   # matches OVERLAY
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

Only the **HEADER** at the top of `configure-overlays.sh` is meant to be edited. Everything else (bucket name, secret names, Loki size, infra placement, ODF claim names, Git TLS defaults) uses fixed project defaults.

```bash
# 1. Edit HEADER values
# 2. Run (no arguments):
./configure-overlays.sh
```

The script is safe to re-run. It will:

- Seed a missing Loki overlay from `overlays/s3` or `overlays/odf`
- Seed a missing S4 overlay from `s4/overlays/lab` when `STORAGE_BACKEND=s4`
- Rewrite patch YAML (storage, placement, credentials, CA)
- Update Argo CD `repoURL`, revision, and the Loki instance path

Full HEADER list: [Appendix](#11-appendix-header-variables).

---

## 4. Choose object storage

Loki always needs S3-compatible storage. Pick **one** option below.

### Option A — In-repo S4 (labs)

S4 ships under `s4/`. Two routes matter:

| Route | Role |
|-------|------|
| `s4` | Web UI and REST API (`/api`) — used to create the bucket |
| `s4-api` | S3 API — **this** is what Loki uses (`S4_API_HOST`) |

**Flow**

1. HEADER: `STORAGE_BACKEND=s4` plus `OVERLAY`, `S4_*`, `LOKI_STORAGE_CLASS`, `GIT_REPO_URL` → `./configure-overlays.sh`
2. `./deploy-s4.sh` — applies `s4/overlays/<OVERLAY>`, creates bucket `loggingstack`
3. HEADER: `S4_DEPLOYED_ON_CLUSTER=true` → `./configure-overlays.sh` again (Loki TLS CA)
4. Deploy logging ([Kustomize](#5-deploy-with-kustomize) or [GitOps](#6-deploy-with-openshift-gitops))

### Option B — External S3

1. Create a bucket and credentials (list/get/put/delete).
2. HEADER:

```bash
OVERLAY="lab"
STORAGE_BACKEND="s3"
LOKI_STORAGE_CLASS="gp3-csi"
S3_ENDPOINT="https://s3.example.com"
S3_ACCESS_KEY="<key>"
S3_SECRET_KEY="<secret>"
S3_BUCKET="loggingstack"
GIT_REPO_URL="https://github.com/<org>/deploy-gitops-logging.git"
```

3. `./configure-overlays.sh` (also fetches the endpoint TLS CA), then deploy logging.

### Option C — ODF / NooBaa

1. Confirm ODF/NooBaa is healthy (`oc get storageclass`, `oc get pods -n openshift-storage`).
2. HEADER:

```bash
OVERLAY="odf"
STORAGE_BACKEND="odf"
LOKI_STORAGE_CLASS="ocs-storagecluster-ceph-rbd"
GIT_REPO_URL="https://github.com/<org>/deploy-gitops-logging.git"
```

3. `./configure-overlays.sh`, then deploy with `logging/loki-instance/overlays/<OVERLAY>`.

After apply, Job `loki-odf-secret-sync` builds Secret `logging-loki-s3`. For Kustomize-only installs you can also run `./scripts/sync-odf-loki-secret.sh`.

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
# Path must match OVERLAY from the HEADER (example: lab)
oc apply -k logging/loki-instance/overlays/lab

# ODF example:
# oc apply -k logging/loki-instance/overlays/odf
# ./scripts/sync-odf-loki-secret.sh   # if Job has not finished

oc get lokistack logging-loki -n openshift-logging -w
```

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
# Edit HEADER (storage + GIT_REPO_URL)
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
# Trust gitops/git-ca.crt in Argo CD (argocd-tls-certs-cm) per OpenShift GitOps docs
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

Placement defaults are fixed in the script (infra label + toleration). To change them, edit the fixed-defaults section in `configure-overlays.sh`, re-run the script, then re-apply or re-sync.

---

## 9. Troubleshooting

| Symptom | What to try |
|---------|-------------|
| Loki pods `Pending` | Label/taint infra nodes; set `LOKI_STORAGE_CLASS` to a StorageClass that exists |
| Bad CA / `invalid document separator` | For S4 set `S4_DEPLOYED_ON_CLUSTER=true` and re-run configure; for external S3 re-run configure so the CA is fetched again |
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

Only these belong in the HEADER. Everything else is a fixed project default inside the script.

| Variable | When | Meaning | Default |
|----------|------|---------|---------|
| `OVERLAY` | always | Logging (and S4) overlay directory name | `lab` |
| `STORAGE_BACKEND` | always | `s4`, `s3`, or `odf` | `s4` |
| `LOKI_STORAGE_CLASS` | always | Block StorageClass for Loki PVCs | `gp3-csi` |
| `S4_API_HOST` | `s4` | S3 Route hostname | `s3.s4.apps.example.com` |
| `S4_ACCESS_KEY` / `S4_SECRET_KEY` | `s4` | S4 / Loki credentials | `s4admin` / `s4secret` |
| `S4_UI_PASSWORD` | `s4` | S4 UI / REST password | `changeme` |
| `S4_DEPLOYED_ON_CLUSTER` | `s4` | Fetch Loki CA after S4 is up | `false` |
| `S3_ENDPOINT` | `s3` | External S3 API URL | `https://s3.example.com` |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | `s3` | External S3 credentials | placeholders |
| `S3_BUCKET` | `s3` | External bucket name | `loggingstack` |
| `GIT_REPO_URL` | always | Argo CD Git repository URL | your fork URL |

**Fixed defaults (not in HEADER):** bucket `loggingstack` for S4, secret name `logging-loki-s3`, Loki size `1x.pico`, 14-day retention, infra node placement, ODF NooBaa StorageClass / OBC names, Git revision `HEAD`, HTTPS insecure for lab Git, kubeconfig `$HOME/ocpkubeconfig`.
