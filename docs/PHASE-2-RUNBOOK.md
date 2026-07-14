# Phase 2 Runbook — Standby Cluster + GCS Backups

Deploy the standby k3s cluster and GCS backup bucket. Run after Phase 1 is verified.

If bootstrap fails (SSH, Helm, Argo CD, apt hangs), see
[GCP-BOOTSTRAP-ISSUES.md](GCP-BOOTSTRAP-ISSUES.md) — most standby failures were
caused by **e2-micro** sizing or stuck Helm release secrets.

## Portable design

Uses **gcp-compute** by default (`cloud-services-gcp/`). For AWS use `cloud-services/` with `aws-ec2`. See [GCP-ARCHITECTURE.md](GCP-ARCHITECTURE.md).

## Step 1 — Configure variables

```bash
cd cloud-services-gcp
cp terraform.tfvars.example terraform.tfvars
# Use same gcp_project, ssh_public_key and admin_cidr as primary-cluster-gcp
# Set standby_machine_type = "e2-small" (default). Do not use e2-micro.
```

If standby VMs already exist as `e2-micro`, update `terraform.tfvars` and re-apply
(`allow_stopping_for_update` stops/starts them in place):

```bash
# cloud-services-gcp/terraform.tfvars
standby_machine_type = "e2-small"
terraform -chdir=cloud-services-gcp apply
```

Or use the deploy script (creates both tfvars files):

```bash
./scripts/gcp-deploy.sh init
```

## Step 2 — Deploy

**GitHub Actions (no local `gcloud login`):**

```bash
gh workflow run gcp-phase2.yml -R dakaii/fantastic-spoon
gh run watch -R dakaii/fantastic-spoon
```

Requires GitHub secrets with a **full** deploy service account — see [GITHUB-ACTIONS-SETUP.md](GITHUB-ACTIONS-SETUP.md).

**Local:**

```bash
./scripts/phase2-standby.sh
# or: ./scripts/gcp-deploy.sh infra   # includes Velero config on primary
```

This creates:
- 2× GCE standby nodes (1 server + 1 agent, e2-small minimum — e2-micro times out during bootstrap)
- GCS bucket for Velero backups
- External TCP load balancer for standby ingress
- HMAC keys for Velero (S3-compatible API)

## Step 3 — Verify standby cluster

```bash
SB_IP=$(grep ansible_host ansible/inventory/standby-hosts.yml | head -1 | awk '{print $2}')
ssh ubuntu@$SB_IP "sudo k3s kubectl get nodes"
```

## Step 4 — Velero on primary

If you used `./scripts/gcp-deploy.sh infra`, Velero on primary is configured automatically.

**Refresh inventory first** — GCP ephemeral IPs change; a stale `primary-hosts.yml`
causes SSH timeouts (e.g. connecting to an old NAT IP).

```bash
GCP_PROJECT=hybrid-k8s-dev ./scripts/generate-gcp-inventory.sh primary
# Confirm SSH works (CP IP is under k3s_server → hosts → ansible_host):
CP=$(awk '/k3s_server:/{f=1} f && /ansible_host:/{print $2; exit}' ansible/inventory/primary-hosts.yml)
ssh ubuntu@"$CP" hostname

./scripts/configure-velero-primary.sh
```

Or skip parsing inventory and ask GCE:

```bash
CP=$(gcloud compute instances list \
  --filter='labels.cluster=primary AND labels.role=server' \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
ssh ubuntu@"$CP" 'sudo k3s kubectl -n velero get pods,backupstoragelocation'
```

Expect `BackupStorageLocation` Phase=`Available`. If you see
`unable to locate ObjectStore plugin named velero.io/aws`, pull the AWS plugin
fix and re-run the script (see [GCP-BOOTSTRAP-ISSUES.md](GCP-BOOTSTRAP-ISSUES.md) §2b).

Manual Ansible alternative (addons only):

```bash
cd cloud-services-gcp
BUCKET=$(terraform output -raw backup_bucket_name)
KEY=$(terraform output -raw velero_access_key_id)
SECRET=$(terraform output -raw velero_secret_access_key)

cd ../ansible
ansible-playbook -i inventory/primary-hosts.yml playbooks/site.yml \
  --tags addons --limit 'k3s_server[0]' \
  -e cluster_profile=primary \
  -e cluster_name=primary \
  -e provisioner=gcp-compute \
  -e "velero_bucket=${BUCKET}" \
  -e "velero_access_key=${KEY}" \
  -e "velero_secret_key=${SECRET}" \
  -e velero_provider=gcp \
  -e velero_region=auto
```

## Step 5 — Register standby in primary Argo CD

On the **primary** cluster:

```bash
export KUBECONFIG=~/.kube/hybrid-primary.yaml

SB_IP=<standby-server-ip>
ssh ubuntu@$SB_IP "sudo k3s kubectl create sa argocd-manager -n kube-system"
ssh ubuntu@$SB_IP "sudo k3s kubectl create clusterrolebinding argocd-manager \
  --clusterrole=cluster-admin --serviceaccount=kube-system:argocd-manager"
TOKEN=$(ssh ubuntu@$SB_IP "sudo k3s kubectl create token argocd-manager -n kube-system")
CA=$(ssh ubuntu@$SB_IP "sudo k3s kubectl get cm kube-root-ca.crt -o jsonpath='{.data.ca\.crt}'")

# Update gitops/argocd/clusters/cloud-standby.yaml with:
#   server: https://<SB_IP>:6443
#   bearerToken: <TOKEN>
#   caData: <CA base64>

kubectl apply -f gitops/argocd/clusters/cloud-standby.yaml
kubectl apply -f gitops/argocd/applications/root-app.yaml
```

Or run `./scripts/gcp-deploy.sh apps` after updating the standby cluster secret.

## Next

→ Phase 3: GitOps app deployment (Linkding via `./scripts/gcp-deploy.sh apps`)
→ Phase 4: Register domain + `shared-services-gcp/` for automated failover

See [GCP-ARCHITECTURE.md](GCP-ARCHITECTURE.md) for the full failover design.
