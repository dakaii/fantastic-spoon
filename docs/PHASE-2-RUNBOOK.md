# Phase 2 Runbook — Standby Cluster + S3 Backups

Deploy the standby k3s cluster and S3 backup bucket. Run after Phase 1 is verified.

## Step 1 — Configure variables

```bash
cd cloud-services
cp terraform.tfvars.example terraform.tfvars
# Use same ssh_public_key and admin_cidr as primary-cluster
```

## Step 2 — Deploy

```bash
./scripts/phase2-standby.sh
```

This creates:
- 2× EC2 standby nodes (1 server + 1 agent)
- S3 bucket for Velero backups
- NLB for standby ingress
- IAM credentials for Velero

## Step 3 — Verify standby cluster

```bash
SB_IP=$(grep ansible_host ansible/inventory/standby-hosts.yml | head -1 | awk '{print $2}')
ssh ubuntu@$SB_IP "sudo k3s kubectl get nodes"
```

## Step 4 — Register standby in primary Argo CD

On the **primary** cluster:

```bash
export KUBECONFIG=~/.kube/hybrid-primary.yaml

# Create argocd-manager SA on standby
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

## Step 5 — Configure Velero on primary

Re-run addons on primary with Velero credentials from Phase 2 outputs:

```bash
cd cloud-services
VELERO_BUCKET=$(terraform output -raw backup_bucket_name)
VELERO_KEY=$(terraform output -raw velero_access_key_id)
VELERO_SECRET=$(terraform output -raw velero_secret_access_key)

cd ../ansible
ansible-playbook -i inventory/primary-hosts.yml playbooks/site.yml \
  -e cluster_profile=primary \
  -e "velero_bucket=${VELERO_BUCKET}" \
  -e "velero_access_key=${VELERO_KEY}" \
  -e "velero_secret_key=${VELERO_SECRET}" \
  --tags never  # or create a velero-only playbook
```

## Next

→ Phase 3: GitOps app deployment
→ Phase 4: Register domain + `shared-services/` for automated failover

See [AWS-ARCHITECTURE.md](AWS-ARCHITECTURE.md) for the full failover design.
