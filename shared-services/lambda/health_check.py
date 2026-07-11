"""Lambda witness — checks primary k3s API health and triggers failover."""

import json
import os
import urllib.error
import urllib.request

import boto3

PRIMARY_API_URL = os.environ["PRIMARY_API_URL"]
FAILURE_THRESHOLD = int(os.environ.get("FAILURE_THRESHOLD", "3"))
STATE_TABLE = os.environ["STATE_TABLE"]
FAILOVER_STATE_MACHINE = os.environ["FAILOVER_STATE_MACHINE"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

dynamodb = boto3.resource("dynamodb")
sfn = boto3.client("stepfunctions")
sns = boto3.client("sns")
table = dynamodb.Table(STATE_TABLE)


def get_state():
    resp = table.get_item(Key={"pk": "health"})
    return resp.get("Item", {"consecutive_failures": 0, "failover_active": False})


def save_state(failures, failover_active):
    table.put_item(
        Item={
            "pk": "health",
            "consecutive_failures": failures,
            "failover_active": failover_active,
        }
    )


def check_health():
    url = f"{PRIMARY_API_URL}/readyz"
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status == 200
    except (urllib.error.URLError, TimeoutError):
        return False


def handler(event, context):
    state = get_state()
    failures = int(state.get("consecutive_failures", 0))
    failover_active = state.get("failover_active", False)

    if check_health():
        save_state(0, failover_active)
        return {"status": "healthy", "failover_active": failover_active}

    failures += 1
    save_state(failures, failover_active)

    if failures >= FAILURE_THRESHOLD and not failover_active:
        sfn.start_execution(
            stateMachineArn=FAILOVER_STATE_MACHINE,
            input=json.dumps({"reason": "primary_unhealthy", "failures": failures}),
        )
        save_state(failures, True)
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="FAILOVER INITIATED",
            Message=f"Primary cluster unhealthy after {failures} checks. Failover workflow started.",
        )
        return {"status": "failover_triggered", "failures": failures}

    return {"status": "unhealthy", "failures": failures, "failover_active": failover_active}
