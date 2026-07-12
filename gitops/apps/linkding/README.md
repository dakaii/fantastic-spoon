# Linkding — First Real App on the Hybrid K8s Platform

Self-hosted bookmark manager. Single container + SQLite on PVC — ideal first workload.

- **Image:** [sissbruecker/linkding](https://hub.docker.com/r/sissbruecker/linkding) (Docker Hub, ARM64 compatible)
- **Port:** 9090
- **Storage:** 2 Gi PVC at `/etc/linkding/data`

## Deploy via Argo CD

Picked up automatically by the `applications` ApplicationSet (`gitops/apps/linkding`).

Or apply manually:

```bash
kubectl apply -k gitops/apps/linkding/
```

## Access

### Option A — Ingress (Traefik)

1. Point DNS or `/etc/hosts` at your cluster:
   ```
   <node-ip>  linkding.local
   ```
2. Open http://linkding.local (or https if cert-manager is configured)

### Option B — Port forward (quick test)

```bash
kubectl port-forward svc/linkding -n linkding 9090:9090
```

Open http://localhost:9090

## First login

On first visit, create your user account — the first registered user becomes admin.

Optional bootstrap via Secret:

```bash
kubectl create secret generic linkding-admin -n linkding \
  --from-literal=username=admin \
  --from-literal=password='change-me'
```

Then uncomment `LD_SUPERUSER_*` env vars in `deployment.yaml`.

## Failover notes

Linkding stores bookmarks in SQLite on the PVC. For DR:

- Include `linkding` namespace in Velero backups
- On standby failover, restore PVC before scaling replicas up
- Standby overlay sets `replicas: 0` until failover

## Resources

| Resource | Value |
|----------|-------|
| CPU request | 50m |
| Memory request | 128Mi |
| PVC | 2Gi |

## Upgrade

Argo CD syncs `sissbruecker/linkding:latest` automatically. Pin a version tag in production:

```yaml
image: sissbruecker/linkding:1.32.0
```
