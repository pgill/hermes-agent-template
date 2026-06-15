#!/bin/bash
# Checks for a new Hermes version and triggers a Railway redeploy if one exists.
# Runs as a Hermes no_agent cron (watchdog pattern: silent when nothing to do).
#
# Delivery: stdout from a no_agent cron is delivered to the user's home channel
# by Hermes automatically — no bot token or chat ID wiring needed in this script.
#
# Required Railway Variable: RAILWAY_API_TOKEN (workspace-scoped token from
# railway.com/account/tokens). RAILWAY_SERVICE_ID and RAILWAY_ENVIRONMENT_ID
# are injected automatically by Railway — no manual configuration needed.
#
# Activation: ask your agent "turn on auto-updates" or
# "check for Hermes updates every week" — it will register this script
# as a weekly Sunday 3am cron and confirm.

set -euo pipefail

VERSION_OUTPUT=$(hermes --version 2>&1 || true)

if ! echo "$VERSION_OUTPUT" | grep -q "Update available"; then
    exit 0
fi

if [ -z "${RAILWAY_API_TOKEN:-}" ]; then
    echo "⚠️ Hermes update available but RAILWAY_API_TOKEN is not set."
    echo "Add it in Railway → Variables (workspace-scoped token from railway.com/account/tokens)."
    echo ""
    echo "$VERSION_OUTPUT"
    exit 1
fi

# RAILWAY_SERVICE_ID and RAILWAY_ENVIRONMENT_ID are injected by Railway
# automatically into every service — no manual setup required.
if [ -z "${RAILWAY_SERVICE_ID:-}" ] || [ -z "${RAILWAY_ENVIRONMENT_ID:-}" ]; then
    echo "⚠️ Hermes update available but RAILWAY_SERVICE_ID or RAILWAY_ENVIRONMENT_ID"
    echo "is missing. This script is designed to run inside a Railway service."
    echo ""
    echo "$VERSION_OUTPUT"
    exit 1
fi

CURRENT=$(echo "$VERSION_OUTPUT" | head -1)
UPDATE_LINE=$(echo "$VERSION_OUTPUT" | grep "Update available")

HTTP_CODE=$(curl -s -o /tmp/railway-redeploy-response.json -w "%{http_code}" \
    -X POST https://backboard.railway.com/graphql/v2 \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RAILWAY_API_TOKEN" \
    -d "{\"query\":\"mutation { serviceInstanceRedeploy(serviceId: \\\"$RAILWAY_SERVICE_ID\\\", environmentId: \\\"$RAILWAY_ENVIRONMENT_ID\\\") }\"}")

RESPONSE=$(cat /tmp/railway-redeploy-response.json 2>/dev/null || echo "{}")

if [ "$HTTP_CODE" != "200" ] || echo "$RESPONSE" | grep -q '"errors"'; then
    echo "⚠️ Hermes update available but redeploy failed (HTTP $HTTP_CODE)."
    echo "$CURRENT"
    echo "$UPDATE_LINE"
    echo "Check your RAILWAY_API_TOKEN in Railway → Variables."
    exit 1
fi

echo "🔄 Hermes update found — redeploying now."
echo "$CURRENT"
echo "$UPDATE_LINE"
echo "Your agent will be back online in ~60 seconds with the new version."
