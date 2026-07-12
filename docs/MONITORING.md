# Monitoring Setup Guide

Prometheus + Grafana + Alertmanager for the hybrid k8s platform.

## Stack overview

| Component | Purpose | Installed by |
|-----------|---------|--------------|
| Prometheus | Metrics collection | Ansible (`kube-prometheus-stack`) |
| Grafana | Dashboards | Same Helm chart |
| Alertmanager | Alert routing | Same Helm chart |
| PrometheusRules (GitOps) | Custom alerts | Argo CD (`infra-monitoring` app) |

**Jaeger/tracing:** not included — add later when you have multiple microservices.

## Quick start

### 1. Verify monitoring is running (after Phase 1 Ansible)

```bash
kubectl get pods -n monitoring
kubectl get prometheusrules -n monitoring
```

### 2. Deploy alert rules + dashboard (Phase 3 GitOps)

```bash
kubectl apply -f gitops/argocd/applications/infra-monitoring.yaml

# Or sync via Argo CD UI: Applications → infra-monitoring → Sync
```

### 3. Open Grafana

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
```

- URL: http://localhost:3000
- User: `admin`
- Password: `changeme` (set during Ansible install — change this)

Navigate to **Dashboards → Hybrid K8s Platform Overview**.

### 4. Verify alerts are loaded

```bash
kubectl get prometheusrules -n monitoring -l app.kubernetes.io/part-of=hybrid-k8s-platform

# In Prometheus UI (optional):
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090
# Open http://localhost:9090/alerts
```

## Alert runbooks

### KubeAPIDown

**Meaning:** Kubernetes API server scrape target is down for 2+ minutes.

**Check:**
```bash
kubectl get nodes
ssh <control-plane> sudo systemctl status k3s
```

**Action:** If cluster is truly dead and Lambda witness hasn't fired, initiate failover manually (`scripts/failover.sh`).

### VeleroBackupFailed

**Meaning:** Scheduled Velero backup did not succeed.

**Check:**
```bash
kubectl get backups -n velero
velero backup logs <backup-name>
```

**Action:** Fix S3 credentials, bucket permissions, or Velero configuration before relying on DR.

### KubeMultipleNodesDown

**Meaning:** More than one node is NotReady for 3+ minutes.

**Action:** Investigate node health. If primary site is failing, prepare for failover.

## Configure Slack alerts

Edit `gitops/infrastructure/primary/monitoring/helm-values-alertmanager.example.yaml`:

```yaml
receivers:
  - name: critical
    slack_configs:
      - api_url: "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
        channel: "#k8s-alerts"
        title: "[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}"
```

Apply:

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f gitops/infrastructure/primary/monitoring/helm-values-alertmanager.example.yaml \
  --reuse-values
```

## Recommended integration order

1. **Now:** Prometheus rules + Grafana dashboard (this PR)
2. **Next:** Alertmanager → Slack/email
3. **Later:** Loki for logs
4. **Much later:** Jaeger/Tempo for tracing

## What not to add yet

- Datadog / New Relic (paid, overkill)
- Full ELK stack (heavy — use Loki instead)
- Service mesh observability (no mesh yet)
