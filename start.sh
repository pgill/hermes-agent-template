#!/bin/bash
set -euo pipefail

export HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
export HOME="${HOME:-/data}"
ENV_FILE="${HERMES_HOME}/.env"
CONFIG_FILE="${HERMES_HOME}/config.yaml"
INITIALIZED_MARKER="${HERMES_HOME}/.initialized"
# Mirror dashboard-ref-only's startup: create every directory Hermes expects
# and seed a default config.yaml if the volume is empty. Without these,
# `hermes dashboard` endpoints that hit logs/, sessions/, cron/, etc. can fail
# with opaque errors even though no auth is actually involved.
mkdir -p "${HERMES_HOME}"/cron "${HERMES_HOME}"/sessions "${HERMES_HOME}"/logs \
         "${HERMES_HOME}"/memories "${HERMES_HOME}"/skills "${HERMES_HOME}"/pairing \
         "${HERMES_HOME}"/hooks "${HERMES_HOME}"/image_cache "${HERMES_HOME}"/audio_cache \
         "${HERMES_HOME}"/workspace "${HERMES_HOME}"/skins "${HERMES_HOME}"/plans \
         "${HERMES_HOME}"/home "${HERMES_HOME}"/scripts "${HERMES_HOME}"/profiles

# Runtime env bridge: Railway Variables live in the container process env, while
# Hermes/GBrain tools and profile gateways read ${HERMES_HOME}/.env. Refresh a
# curated set on every boot so Railway stays the source of truth for runtime
# secrets, but preserve file-only values that Hermes created on the volume.
if [ -f /app/sync_railway_env.py ]; then
  python /app/sync_railway_env.py
else
  # Allows local smoke tests from the repo checkout before Docker COPY runs.
  python "$(dirname "$0")/sync_railway_env.py"
fi

if [ ! -f "${CONFIG_FILE}" ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example "${CONFIG_FILE}"
fi

touch "${ENV_FILE}"
chmod 600 "${ENV_FILE}" || true

# If Railway provides a Supabase transaction-pooler URL under the user-friendly
# name, expose it under the canonical GBrain env var as well. GBrain reads
# GBRAIN_DATABASE_URL / DATABASE_URL directly; keeping GBRAIN_SUPABASE_URL in
# .env is still useful as the operator-facing Railway variable.
if [ -n "${GBRAIN_SUPABASE_URL:-}" ] && [ -z "${GBRAIN_DATABASE_URL:-}" ]; then
  export GBRAIN_DATABASE_URL="${GBRAIN_SUPABASE_URL}"
fi

# Bootstrap OAuth tokens from env var (e.g. xAI Grok SuperGrok).
# Set HERMES_AUTH_JSON_BOOTSTRAP to the contents of a locally-generated
# ~/.hermes/auth.json. Written only once — subsequent token refreshes update
# the file in place on the persistent volume.
if [ ! -f "${HERMES_HOME}/auth.json" ] && [ -n "${HERMES_AUTH_JSON_BOOTSTRAP:-}" ]; then
  printf '%s' "${HERMES_AUTH_JSON_BOOTSTRAP}" > "${HERMES_HOME}/auth.json"
  chmod 600 "${HERMES_HOME}/auth.json"
fi

# Optional first-run marker for downstream boot hooks/diagnostics. Do not put
# expensive setup here: config/secrets are intentionally refreshed every boot.
if [ ! -f "${INITIALIZED_MARKER}" ]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "${INITIALIZED_MARKER}"
fi

# Clear stale gateway PID files left over from the previous container.
# `hermes gateway` writes gateway.pid on start but may not remove it on SIGTERM.
# Since /data is a persistent volume, stale PID files can survive container
# restarts and cause subsequent boots to exit with "PID file race lost". No
# hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing these files unconditionally is safe.
rm -f "${HERMES_HOME}/gateway.pid"
find "${HERMES_HOME}/profiles" -mindepth 2 -maxdepth 2 -name gateway.pid -type f -delete 2>/dev/null || true

exec python /app/server.py
