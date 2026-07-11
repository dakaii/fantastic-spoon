#!/usr/bin/env bash
# failover.sh — Automated failover from local primary to cloud standby
set -euo pipefail

CLOUD_SERVER="${CLOUD_SERVER:-https://CLOUD_STANDBY_API_IP:6443}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_RECORD_ID="${CF_RECORD_ID:-}"
CF_TOKEN="${CF_TOKEN:-}"
CLOUD_LB_IP="${CLOUD_LB_IP:-}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
STATE_FILE="${STATE_FILE:-/tmp/failover-state.json}"

notify() {
  local message="$1"
  echo "$message"
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    curl -s -X POST "$SLACK_WEBHOOK" \
      -H "Content-Type: application/json" \
      -d "{\"text\": \"$message\"}" > /dev/null
  fi
}

notify ":rotating_light: FAILOVER INITIATED — switching to cloud standby"

# Step 1: Restore latest Velero backup to cloud cluster (if needed)
if command -v velero &> /dev/null; then
  LATEST=$(velero backup get --output json | jq -r '.items | sort_by(.status.startTimestamp) | last | .metadata.name')
  if [[ -n "$LATEST" && "$LATEST" != "null" ]]; then
    notify "Restoring Velero backup: $LATEST"
    velero restore create "failover-$(date +%s)" --from-backup "$LATEST" --wait
  fi
fi

# Step 2: Patch all Argo CD Applications to cloud standby
notify "Patching Argo CD applications to cloud standby"
for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
  kubectl patch application "$app" -n argocd --type merge -p "{
    \"spec\": {
      \"destination\": {
        \"server\": \"${CLOUD_SERVER}\"
      }
    }
  }"
done

# Step 3: Force sync all applications
if command -v argocd &> /dev/null; then
  argocd app sync --all --force --timeout 600
fi

# Step 4: Update DNS to point to cloud load balancer
if [[ -n "$CF_ZONE_ID" && -n "$CF_RECORD_ID" && -n "$CF_TOKEN" && -n "$CLOUD_LB_IP" ]]; then
  notify "Updating Cloudflare DNS to ${CLOUD_LB_IP}"
  curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${CF_RECORD_ID}" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"app\",\"content\":\"${CLOUD_LB_IP}\",\"ttl\":60,\"proxied\":true}" \
    > /dev/null
fi

# Step 5: Mark failover as active
echo '{"consecutive_failures": 0, "failover_active": true}' > "$STATE_FILE"

notify ":white_check_mark: FAILOVER COMPLETE — traffic routed to cloud standby"
