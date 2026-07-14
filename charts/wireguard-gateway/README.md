# wireguard-gateway (future in-cluster packaging)

**Not used by V1.** V1 runs WireGuard on a dedicated GCE VM via
`ansible/playbooks/vpn-gateway.yml` so it never joins primary/standby k3s and
is **not** auto-synced by Argo ApplicationSets under `gitops/apps/*`.

When gateways join a labeled k3s pool (Phase V3+), promote this into
`gitops/apps/wireguard-gateway/` carefully (privileged / hostNetwork).

Placeholder values for a future Helm/Kustomize chart live here only as a stub.

```yaml
# Future Deployment sketch — do not apply to primary today
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: wireguard-gateway
#   namespace: vpn
```
