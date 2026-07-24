"""Level C activate-apps — scale standby workloads when failover Workflow runs.

Opt-in via enable_level_c_automation. Loads kubeconfig from Secret Manager,
pauses Argo automated sync (so Git replicas:0 does not selfHeal), then scales
known Deployments to 1. Velero restore is NOT performed (hint only).
"""

from __future__ import annotations

import base64
import json
import os
import tempfile
from typing import Any

import functions_framework
from google.cloud import secretmanager
from kubernetes import client as k8s_client
from kubernetes import config as k8s_config
from kubernetes.client.exceptions import ApiException

SECRET_ID = os.environ.get(
    "STANDBY_KUBECONFIG_SECRET", "hybrid-k8s-standby-kubeconfig"
)
GCP_PROJECT = os.environ["GCP_PROJECT"]

# namespace/name — demo-app lives in namespace demo-app (not "demo")
SCALE_TARGETS = (
    ("linkding", "linkding"),
    ("demo-app", "demo-app"),
)

# Argo Applications to pause so selfHeal does not revert replicas:0 overlays
ARGO_APPS = ("linkding", "demo-app")


def _load_kubeconfig_yaml() -> str:
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{GCP_PROJECT}/secrets/{SECRET_ID}/versions/latest"
    resp = client.access_secret_version(request={"name": name})
    raw = resp.payload.data
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return base64.b64decode(raw).decode("utf-8")


def _api_client():
    yaml_text = _load_kubeconfig_yaml()
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as fh:
        fh.write(yaml_text)
        path = fh.name
    k8s_config.load_kube_config(config_file=path)
    # k3s self-signed cert — match witness TLS skip
    conf = k8s_client.Configuration.get_default_copy()
    conf.verify_ssl = False
    k8s_client.Configuration.set_default(conf)
    return k8s_client.AppsV1Api(), k8s_client.CustomObjectsApi()


def _pause_argo(custom: k8s_client.CustomObjectsApi) -> list[dict[str, Any]]:
    results = []
    for app in ARGO_APPS:
        try:
            custom.patch_namespaced_custom_object(
                group="argoproj.io",
                version="v1alpha1",
                namespace="argocd",
                plural="applications",
                name=app,
                body={"spec": {"syncPolicy": None}},
            )
            results.append({"app": app, "status": "sync_paused"})
        except ApiException as exc:
            if exc.status == 404:
                results.append({"app": app, "status": "not_found"})
            else:
                results.append({"app": app, "status": "error", "detail": str(exc.reason)})
    return results


def _scale(apps: k8s_client.AppsV1Api) -> list[dict[str, Any]]:
    results = []
    for ns, name in SCALE_TARGETS:
        try:
            apps.patch_namespaced_deployment_scale(
                name=name,
                namespace=ns,
                body={"spec": {"replicas": 1}},
            )
            results.append({"namespace": ns, "name": name, "status": "scaled_to_1"})
        except ApiException as exc:
            if exc.status == 404:
                results.append({"namespace": ns, "name": name, "status": "not_found"})
            else:
                results.append(
                    {
                        "namespace": ns,
                        "name": name,
                        "status": "error",
                        "detail": str(exc.reason),
                    }
                )
    return results


@functions_framework.http
def activate_apps(request):
    """HTTP entry — called by Cloud Workflows with OIDC."""
    try:
        apps_api, custom_api = _api_client()
    except Exception as exc:  # noqa: BLE001 — surface secret/kubeconfig errors
        body = {
            "status": "error",
            "error": f"kubeconfig_load_failed: {exc}",
            "hint": "Re-run ./scripts/seed-standby-kubeconfig.sh after standby bootstrap",
        }
        return (json.dumps(body), 500, {"Content-Type": "application/json"})

    argo = _pause_argo(custom_api)
    scaled = _scale(apps_api)
    ok = any(r.get("status") == "scaled_to_1" for r in scaled)

    body = {
        "status": "ok" if ok else "partial_or_empty",
        "argo": argo,
        "scaled": scaled,
        "velero_hint": (
            "Scale ≠ data restore. If you need PVCs: "
            "velero restore create failover-$(date +%s) --from-backup <NAME> --wait"
        ),
        "failback": (
            "Reset Firestore witness/health failover_active=false; "
            "scale standby apps to 0; re-enable Argo sync if desired. "
            "See ./scripts/failover-gcp.sh failback-notes"
        ),
    }
    code = 200 if ok else 207
    return (json.dumps(body), code, {"Content-Type": "application/json"})
