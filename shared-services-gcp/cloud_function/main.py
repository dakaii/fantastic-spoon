"""Cloud Function witness — checks primary k3s API health and triggers failover."""

import json
import os
import urllib.error
import urllib.request

import functions_framework
from google.cloud import firestore
from google.cloud.workflows.executions_v1 import ExecutionsClient
from google.cloud.workflows.executions_v1.types import Execution
from google.cloud import pubsub_v1

PRIMARY_API_URL = os.environ["PRIMARY_API_URL"]
FAILURE_THRESHOLD = int(os.environ.get("FAILURE_THRESHOLD", "3"))
FAILOVER_WORKFLOW_ID = os.environ["FAILOVER_WORKFLOW_ID"]
PUBSUB_TOPIC = os.environ["PUBSUB_TOPIC"]
GCP_PROJECT = os.environ["GCP_PROJECT"]
GCP_REGION = os.environ.get("GCP_REGION", "us-central1")

db = firestore.Client()
executions_client = ExecutionsClient()
publisher = pubsub_v1.PublisherClient()


def get_state():
    doc = db.collection("witness").document("health").get()
    if doc.exists:
        return doc.to_dict()
    return {"consecutive_failures": 0, "failover_active": False}


def save_state(failures, failover_active):
    db.collection("witness").document("health").set(
        {"consecutive_failures": failures, "failover_active": failover_active}
    )


def check_health():
    url = f"{PRIMARY_API_URL}/readyz"
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status == 200
    except (urllib.error.URLError, TimeoutError):
        return False


def publish_alert(subject, message):
    data = json.dumps({"subject": subject, "message": message}).encode("utf-8")
    publisher.publish(PUBSUB_TOPIC, data)


def trigger_failover(failures):
    parent = FAILOVER_WORKFLOW_ID
    execution = Execution(
        argument=json.dumps({"reason": "primary_unhealthy", "failures": failures})
    )
    return executions_client.create_execution(parent=parent, execution=execution)


@functions_framework.http
def health_check(request):
    state = get_state()
    failures = int(state.get("consecutive_failures", 0))
    failover_active = state.get("failover_active", False)

    if check_health():
        save_state(0, failover_active)
        return {"status": "healthy", "failover_active": failover_active}, 200

    failures += 1
    save_state(failures, failover_active)

    if failures >= FAILURE_THRESHOLD and not failover_active:
        trigger_failover(failures)
        save_state(failures, True)
        publish_alert(
            "FAILOVER INITIATED",
            f"Primary cluster unhealthy after {failures} checks. Failover workflow started.",
        )
        return {"status": "failover_triggered", "failures": failures}, 200

    return {
        "status": "unhealthy",
        "failures": failures,
        "failover_active": failover_active,
    }, 200
