#!/usr/bin/env bash
# health-check.sh — Poll local k3s API server health
# Used by the cloud witness (Lambda or cron) to detect failures.
set -euo pipefail

LOCAL_API="${LOCAL_API_URL:-https://192.168.122.10:6443}"
TIMEOUT="${HEALTH_CHECK_TIMEOUT:-5}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"
STATE_FILE="${STATE_FILE:-/tmp/failover-state.json}"

check_health() {
  curl -sk --max-time "$TIMEOUT" "${LOCAL_API}/readyz" > /dev/null 2>&1
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    echo '{"consecutive_failures": 0, "failover_active": false}'
  fi
}

save_state() {
  echo "$1" > "$STATE_FILE"
}

STATE=$(load_state)
FAILURES=$(echo "$STATE" | jq -r '.consecutive_failures')
FAILOVER_ACTIVE=$(echo "$STATE" | jq -r '.failover_active')

if check_health; then
  save_state "$(echo "$STATE" | jq '.consecutive_failures = 0')"
  echo "OK: Local cluster healthy"
  exit 0
else
  FAILURES=$((FAILURES + 1))
  save_state "$(echo "$STATE" | jq --argjson f "$FAILURES" '.consecutive_failures = $f')"
  echo "WARN: Health check failed (${FAILURES}/${FAILURE_THRESHOLD})"

  if [[ "$FAILURES" -ge "$FAILURE_THRESHOLD" && "$FAILOVER_ACTIVE" == "false" ]]; then
    echo "CRITICAL: Threshold reached — triggering failover"
    exec "$(dirname "$0")/failover.sh"
  fi

  exit 1
fi
