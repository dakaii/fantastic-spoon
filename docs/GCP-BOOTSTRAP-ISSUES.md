# GCP Bootstrap Issues Log

Errors and bugs hit while bringing up primary/standby on GCP (`hybrid-k8s-dev`),
with the fix that landed (or the workaround). Use this when a bootstrap run fails
again — many symptoms share one root cause (undersized VMs or stuck Helm state).

Related: [GITHUB-ACTIONS-SETUP.md](GITHUB-ACTIONS-SETUP.md) (short fix table),
[PHASE-1-RUNBOOK.md](PHASE-1-RUNBOOK.md), [PHASE-2-RUNBOOK.md](PHASE-2-RUNBOOK.md).

---

## Summary

| Area | Root cause pattern | Lesson |
|------|--------------------|--------|
| Machine size | `e2-small` CP / `e2-micro` standby starve apt + k3s API | Primary CP ≥ `e2-medium`; standby ≥ `e2-small` |
| Firewall | Stale `admin_cidr` blocks SSH from laptop / GHA | Update CIDR or temporarily `0.0.0.0/0`, then re-apply |
| Helm / Argo CD | Stuck `pending-install`, NodePort clash, hook timeouts | Cleanup secrets, skip heavy wait, unique NodePorts |
| Velero | Install with empty bucket / missing `provider` | Skip until Phase 2 bucket + HMAC exist |
| GHA Phase 2 | SA cannot enable APIs / empty remote TF state | Enable APIs as owner; push local state; grant SA roles |
| Auth | `invalid_grant` / RAPT on ADC | Re-run `./scripts/gcp-auth.sh` |

---

## Primary cluster

### 1. Argo CD NodePort already allocated (`30080`)

**Symptom**

```text
Service "argocd-server" is invalid: spec.ports[0].nodePort: Invalid value: 30080:
provided port is already allocated
```

Helm: `Release "argocd" does not exist. Installing it now.` then fails.

**Cause**  
Traefik (or another Service) already owned NodePort `30080`. Argo CD values reused that port.

**Fix**  
Use dedicated ports (`32080` / `32443`) in `gitops/argocd/*/values.yaml` (PR #26).

**Example runs**  
Failed before NodePort change; primary bootstrap succeeded after (e.g. `29231331169`).

---

### 2. Velero install without backup target

**Symptom**

```text
VolumeSnapshotLocation.velero.io "default" is invalid: spec.provider: Required value
```

Task: `Install Velero (AWS S3)` during primary bootstrap.

**Cause**  
Phase 1 bootstrap always tried to install Velero before the GCS bucket / HMAC keys
from Phase 2 (`cloud-services-gcp`) existed. Chart created incomplete CRDs.

**Fix**  
Detect configured backup target; skip Velero with a clear message until Phase 2
(PR #27, `k3s-addons` tasks).

**Follow-up**  
After standby infra: `./scripts/configure-velero-primary.sh` or `gcp-deploy.sh infra`.

---

### 2b. Velero BSL Unavailable — missing AWS plugin

**Symptom**

```text
BackupStorageLocation "default" is unavailable: unable to locate ObjectStore plugin named velero.io/aws
```

Pod Running, BSL Phase `Unavailable`.

**Cause**  
The Velero Helm chart does not install object-store plugins by default. GCS is
accessed via the S3-compatible API (`provider: aws`), so `velero-plugin-for-aws`
must be an `initContainer`.

**Fix**  
Add `initContainers` with `velero/velero-plugin-for-aws` (and
`checksumAlgorithm: ""` for GCS). Re-run:

```bash
GCP_PROJECT=hybrid-k8s-dev ./scripts/configure-velero-primary.sh
```

Then check: `kubectl -n velero get backupstoragelocation` → `Available`.

---

### 3. Control plane OOM / API timeouts on `e2-small`

**Symptom**  
`kubectl` / Helm hang or TLS errors; Cilium/Longhorn/Argo CD pressure on 2 GB CP.

**Cause**  
Full primary stack (k3s + Cilium + Longhorn + Argo CD + kube-prometheus) needs
more than `e2-small` on the control plane.

**Fix**  
Default `control_plane_machine_type` → `e2-medium`. Resize existing VMs (stop →
`set-machine-type` → start) or Terraform apply. See
[GITHUB-ACTIONS-SETUP.md](GITHUB-ACTIONS-SETUP.md).

---

### 4. Cilium certificate / wrong API host after GCP IP change

**Symptom**  
Cilium TLS: certificate valid for old address, not new external IP; stuck or broken
Cilium Helm release after ephemeral public IP change.

**Cause**  
Cilium was pointed at the **external** NAT IP. GCP ephemeral IPs change; the
cluster API is on the **internal** VPC address.

**Fix**  
`k8sServiceHost` = internal IP (e.g. `10.1.0.4`). Reset broken Cilium release before
reinstall in `k3s-addons`.

---

## Standby cluster

### 5. SSH timeout — `admin_cidr` too narrow

**Symptom**

```text
Waiting for 2 nodes (timeout: 300s)...
  · 104.198.x.x (not ready)
Timeout: only 0/2 nodes ready.
```

Local `bootstrap-cluster.sh` and GHA (`29233191860`) both failed. VMs were `RUNNING`.

**Cause**  
Terraform captured an old laptop/GHA egress IP in `admin_cidr` for SSH / k3s API
firewall rules. Current client IP was denied.

**Fix / workaround**  
Update `cloud-services-gcp/terraform.tfvars` (`admin_cidr`), `terraform apply`. For
dev, temporary `0.0.0.0/0` unblocks; tighten later.

---

### 6. Helm “Unable to determine Helm version” on standby

**Symptom**

```text
Add Helm repos ... Unable to determine Helm version
```

Right after `Install Helm` on standby (`k3s-addons-standby`).

**Cause**  
Race / incomplete Helm binary visibility to the Ansible Helm module on slow nodes;
version probe failed immediately after install.

**Fix**  
Shared `ansible/includes/helm-prereqs.yml`: pin Helm **v3.17.3**, wait until
`helm version` works before repo add (PR #29).

---

### 7. Resource quota evaluation timed out (Argo CD namespace)

**Symptom**

```text
Error from server (InternalError): error when creating "STDIN":
Internal error occurred: resource quota evaluation timed out
```

Task: `Ensure Argo CD namespace and Redis secret exist` (`29238209995`).

**Cause**  
API server overloaded on **e2-micro** standby; simple `kubectl apply` for namespace
took >1 minute and still failed.

**Fix**  
`argocd-prereqs.yml`: wait for API responsiveness, retries (PR #30). Still needs
adequate VM size (§11).

---

### 8. Argo CD Helm `--wait` / API context deadline

**Symptom**

```text
Error: create: failed to create: Timeout: request did not complete within
requested timeout - context deadline exceeded
```

or Helm upgrade with `--wait --timeout 15m` never finishing (`29239075476`).

**Cause**  
On tiny nodes the API cannot process the full Argo CD chart create within client
deadlines; `--wait` compounds the problem.

**Fix**  
Install chart **without** Helm `--wait`; poll deployments with kubectl retries
(`argocd-helm-install.yml`, PR #31).

---

### 9. Stuck Helm release — “another operation is in progress”

**Symptom**

```text
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
```

After a timed-out install left secrets `sh.helm.release.v1.argocd.v*` in
`pending-install` (`29240764681`).

**Cause**  
Failed Helm operations leave release secrets; retries hit the in-progress lock.
Concurrent bootstrap runs make this worse.

**Fix**  
- Automation: `argocd-helm-cleanup.yml` uninstall + delete stuck release secrets
  between retries (PR #32).
- Manual:

```bash
ssh ubuntu@<standby-server> '
  sudo helm uninstall argocd -n argocd --no-hooks 2>/dev/null
  sudo k3s kubectl get secrets -n argocd -o name \
    | grep sh.helm.release.v1.argocd \
    | xargs -r sudo k3s kubectl delete -n argocd --ignore-not-found
'
```

**Rule**  
Do not run two `gcp-bootstrap` workflows on the same cluster at once.

---

### 10. Traefik Helm fails querying API (`INTERNAL_ERROR`)

**Symptom**

```text
Error: query: failed to query with labels: Get "https://127.0.0.1:6443/api/v1/namespaces/traefik/secrets?...":
stream error: stream ID 3; INTERNAL_ERROR; received from peer
```

(`29243334470`, Install Traefik on standby.)

**Cause**  
k3s API becoming unstable under memory/CPU pressure on **e2-micro**.

**Fix**  
Resize off e2-micro (§11); re-run bootstrap after API is healthy.

---

### 11. GHA job timeout — apt stuck on e2-micro

**Symptom**  
Run `29300337076`: job canceled at **1h30m**. Log stuck on
`common : Install required packages` for ~89 minutes with no completion.

**Cause**  
`e2-micro` (1 GB) cannot sustain apt + package install under load; Ansible never
returns. Not a missing package — capacity.

**Fix**  
Default `standby_machine_type` → **`e2-small`** (PR #33). Resize existing VMs:

```bash
# cloud-services-gcp/terraform.tfvars
standby_machine_type = "e2-small"
terraform -chdir=cloud-services-gcp apply   # allow_stopping_for_update stops/starts
```

Then:

```bash
gh workflow run gcp-bootstrap.yml -f cluster=standby -R dakaii/fantastic-spoon
```

Use `e2-medium` if e2-small still struggles under Traefik + Argo CD.

---

## GitHub Actions / Terraform / auth

### 12. Phase 2 workflow — Cloud Resource Manager / enable APIs denied

**Symptom** (`29237702775`)

```text
Cloud Resource Manager API has not been used ... SERVICE_DISABLED
Permission denied to enable service [compute.googleapis.com] ...
AUTH_PERMISSION_DENIED
```

**Cause**  
`github-actions@...` SA lacks permission to enable services; some APIs disabled
in the project. Local owner login can enable them; GHA SA often cannot.

**Fix**  
As project owner:

```bash
./scripts/gcp-setup-github-actions.sh --full --push-secrets
# or manually: gcloud services enable ... ; grant roles/serviceusage.serviceUsageAdmin, etc.
```

Until then prefer **local** `./scripts/provision.sh standby` + GHA **GCP Bootstrap**
only (inventory + Ansible), not full `gcp-phase2.yml`.

---

### 13. Phase 2 — “No remote state yet” while VMs already exist

**Symptom**  
GHA Phase 2 creates a new GCS tfstate bucket and reports empty state; local
Terraform already manages live resources.

**Cause**  
State lived only on the laptop. CI started from empty remote state → risk of
duplicate resources or plan confusion.

**Fix**  
`./scripts/gcp-tfstate-sync.sh push` (see GITHUB-ACTIONS-SETUP) before relying on
CI Terraform. Bootstrap-only workflow does not need remote TF state.

---

### 14. GCP ADC `invalid_grant` / RAPT

**Symptom**

```text
oauth2: "invalid_grant" "reauth related error (invalid_rapt)"
```

Terraform reading `ubuntu-os-cloud` image family.

**Cause**  
Stale Application Default Credentials / Google Workspace reauth policy.

**Fix**

```bash
GCP_PROJECT=hybrid-k8s-dev GCP_ACCOUNT=you@gmail.com ./scripts/gcp-use-project.sh
./scripts/gcp-auth.sh
```

---

### 15. Wrong gcloud account / quota project warnings

**Symptom**  
403s, or “active project does not match the quota project in ADC”.

**Fix**  
`GCP_PROJECT=... ./scripts/gcp-use-project.sh` and refresh ADC so quota project
matches.

---

### 16. Velero on primary — SSH to stale CP IP / worker `k3s_node_token`

**Symptom**

```text
Failed to connect to the host via ssh: ... 136.x.x.x port 22: Operation timed out
object of type 'HostVarsVars' has no attribute 'k3s_node_token'
```

while running `./scripts/configure-velero-primary.sh`.

**Cause**  
`ansible/inventory/primary-hosts.yml` still had an **old ephemeral NAT IP**. Full
`site.yml` then failed on the CP and left workers without `k3s_node_token`.

**Fix**  
Refresh inventory, confirm SSH, then run addons-only Velero config:

```bash
GCP_PROJECT=hybrid-k8s-dev ./scripts/generate-gcp-inventory.sh primary
./scripts/configure-velero-primary.sh   # regenerates inventory + --tags addons
```

If SSH still times out, update `admin_cidr` on the **primary** firewall (same as §5).

---

## Checklist after a failed bootstrap

1. Confirm machine types (primary CP `e2-medium`, standby ≥ `e2-small`).
2. Confirm SSH: `ssh ubuntu@<ip> hostname` (firewall / `admin_cidr`).
3. On the server: `sudo k3s kubectl get nodes`; `sudo helm list -A`.
4. Clear stuck Argo CD Helm release secrets if present (§9).
5. Do not start a second concurrent GHA bootstrap on the same cluster.
6. Re-run **GCP Bootstrap** with `cluster=primary|standby` only after capacity and
   SSH are OK — for Velero, finish Phase 2 bucket first.

---

## PR / fix index

| PR | Issue |
|----|--------|
| #26 | Argo CD NodePorts avoid Traefik `30080` |
| #27 | Skip Velero when backup target unset |
| #28 | GCP Phase 2 GHA workflow |
| #29 | Helm pin + wait before repo add (standby) |
| #30 | Argo CD prereqs / API wait |
| #31 | Argo CD Helm install without `--wait` |
| #32 | Clear stuck Argo CD Helm releases between retries |
| #33 | Standby default machine type `e2-small` |

---

## Known good reference (primary)

After a successful primary bootstrap (e.g. run `29231331169`):

- Nodes Ready (1 CP + 2 workers)
- Namespaces healthy: `argocd`, `monitoring`, `longhorn-system`, `traefik`, `velero` (when configured), Cilium in `kube-system`
- Argo CD UI: NodePort `32080` on the control-plane public IP

Standby is healthy only after resize off `e2-micro` and a clean bootstrap with
stuck Helm state cleared.
