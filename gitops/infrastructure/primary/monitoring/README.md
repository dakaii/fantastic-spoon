# Monitoring — Prometheus Alerts + Grafana Dashboard

Observability for the hybrid k8s platform: cluster health, DR readiness, and GitOps status.

## What's included

| File | Purpose |
|------|---------|
| `prometheus-rules-cluster-health.yaml` | Node/API/workload/storage alerts |
| `prometheus-rules-platform.yaml` | Velero, Argo CD, Traefik alerts |
| `grafana-dashboard-configmap.yaml` | "Hybrid K8s Platform Overview" dashboard |
| `helm-values-alertmanager.example.yaml` | Alertmanager Slack/email config template |

## Prerequisites

- `kube-prometheus-stack` installed (Ansible `k3s-addons` role does this)
- Argo CD running (to sync this folder via `infra-monitoring` Application)

## Deploy via Argo CD

The root App-of-Apps picks up `gitops/argocd/applications/infra-monitoring.yaml` automatically.

Or apply manually:

```bash
kubectl apply -f gitops/argocd/applications/infra-monitoring.yaml
```

## Access Grafana

```bash
# Port-forward Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80

# Default login (change after Ansible install):
# user: admin  password: changeme
```

Open http://localhost:3000 → Dashboards → **Hybrid K8s Platform Overview**

## Critical alerts (failover-related)

| Alert | Severity | Meaning |
|-------|----------|---------|
| `KubeAPIDown` | critical | API server unreachable — evaluate failover |
| `KubeMultipleNodesDown` | critical | Cluster degraded |
| `VeleroBackupFailed` | critical | DR backups broken |
| `VeleroNoRecentBackup` | warning | No backup in 6+ hours |
| `TraefikDown` | critical | No ingress — traffic can't flow |
| `ArgoCDAppUnhealthy` | warning | GitOps drift |

## Configure Alertmanager notifications

1. Copy `helm-values-alertmanager.example.yaml`
2. Add your Slack webhook or email settings
3. Upgrade the Helm release:

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f gitops/infrastructure/primary/monitoring/helm-values-alertmanager.example.yaml \
  --reuse-values
```

## Failover integration

Prometheus alerts complement (but do not replace) the Lambda witness:

```
Prometheus/Alertmanager  →  Slack/email (human awareness)
Lambda witness           →  Automated Route53 failover
```

Both should fire on API server failure — independent paths are intentional.

See [docs/MONITORING.md](../../../docs/MONITORING.md) for full setup guide.
