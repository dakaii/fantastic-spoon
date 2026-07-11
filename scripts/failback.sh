#!/usr/bin/env bash
# failback.sh — Restore traffic to local primary after recovery
set -euo pipefail

LOCAL_SERVER="${LOCAL_SERVER:-https://kubernetes.default.svc}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_RECORD_ID="${CF_RECORD_ID:-}"
CF_TOKEN="${CF_TOKEN:-}"
LOCAL_LB_IP="${LOCAL_LB_IP:-}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
STATE_FILE="${STATE_FILE:-/tmp/failover-state.json}"
HEALTH_CHECKS="${HEALTH_CHECKS:-5}"

notify() {
  local message="$1"
  echo "$message"
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    curl -s -X POST "$SLACK_WEBHOOK" \
      -H "Content-Type: application/json" \
      -d "{\"text\": \"$message\"}" > /dev/null
  fi
}

# Step 1: Verify local cluster is healthy
notify "Verifying local cluster health (${HEALTH_CHECKS} checks)..."
for i in $(seq 1 "$HEALTH_CHECKS"); do
  if ! curl -sk --max-time 5 "${LOCAL_SERVER}/readyz" > /dev/null 2>&1; then
    notify ":x: FAILBACK ABORTED — local cluster not healthy (check ${i}/${HEALTH_CHECKS})"
    exit 1
  fi
  sleep 10
done

notify ":recycle: FAILBACK INITIATED — restoring local primary"

# Step 2: Patch Argo CD Applications back to local
for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
  kubectl patch application "$app" -n argocd --type merge -p "{
    \"spec\": {
      \"destination\": {
        \"server\": \"${LOCAL_SERVER}\"
      }
    }
  }"
done

# Step 3: Force sync
if command -v argocd &> /dev/null; then
  argocd app sync --all --force --timeout 600
fi

# Step 4: Update DNS back to local
if [[ -n "$CF_ZONE_ID" && -n "$CF_RECORD_ID" && -n "$CF_TOKEN" && -n "$LOCAL_LB_IP" ]]; then
  notify "Updating Cloudflare DNS to ${LOCAL_LB_IP}"
  curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${CF_RECORD_ID}" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"app\",\"content\":\"${LOCAL_LB_IP}\",\"ttl\":60,\"proxied\":true}" \
    > /dev/null
fi

# Step 5: Reset failover state
echo '{"consecutive_failures": 0, "failover_active": false}' > "$STATE_FILE"

notify ":white_check_mark: FAILBACK COMPLETE — traffic restored to local primary"
