#!/bin/bash
set -euo pipefail

export HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
export HOME="${HOME:-/data}"
ENV_FILE="${HERMES_HOME}/.env"
CONFIG_FILE="${HERMES_HOME}/config.yaml"
INITIALIZED_MARKER="${HERMES_HOME}/.initialized"
mkdir -p "${HERMES_HOME}"/cron "${HERMES_HOME}"/sessions "${HERMES_HOME}"/logs \
         "${HERMES_HOME}"/memories "${HERMES_HOME}"/skills "${HERMES_HOME}"/pairing \
         "${HERMES_HOME}"/hooks "${HERMES_HOME}"/image_cache "${HERMES_HOME}"/audio_cache \
         "${HERMES_HOME}"/workspace "${HERMES_HOME}"/skins "${HERMES_HOME}"/plans \
         "${HERMES_HOME}"/home "${HERMES_HOME}"/scripts "${HERMES_HOME}"/profiles

# Refresh runtime-managed env vars from Railway on every boot.
if [ -f /app/sync_railway_env.py ]; then
  python /app/sync_railway_env.py
else
  python "$(dirname "$0")/sync_railway_env.py"
fi

# Make the cloud-backed GBrain path explicit: if Supabase is configured, mirror
# it into the canonical GBrain env vars and derive the session-pooler direct
# URL for migrations, DDL, and worker locks.
if [ -n "${GBRAIN_SUPABASE_URL:-}" ] && [ -z "${GBRAIN_DATABASE_URL:-}" ]; then
  export GBRAIN_DATABASE_URL="${GBRAIN_SUPABASE_URL}"
fi
if [ -z "${GBRAIN_DIRECT_DATABASE_URL:-}" ] && [ -n "${GBRAIN_DATABASE_URL:-}" ]; then
  case "${GBRAIN_DATABASE_URL}" in
    *:6543/*)
      export GBRAIN_DIRECT_DATABASE_URL="$(printf '%s' "${GBRAIN_DATABASE_URL}" | sed 's/:6543\//:5432\//')"
      ;;
  esac
fi

# Seed config only once; preserve user changes thereafter.
if [ ! -f "${CONFIG_FILE}" ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example "${CONFIG_FILE}"
fi

touch "${ENV_FILE}"
chmod 600 "${ENV_FILE}" || true

# Bootstrap OAuth tokens from env var (e.g. xAI Grok SuperGrok).
if [ ! -f "${HERMES_HOME}/auth.json" ] && [ -n "${HERMES_AUTH_JSON_BOOTSTRAP:-}" ]; then
  printf '%s' "${HERMES_AUTH_JSON_BOOTSTRAP}" > "${HERMES_HOME}/auth.json"
  chmod 600 "${HERMES_HOME}/auth.json"
fi

if [ ! -f "${INITIALIZED_MARKER}" ]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "${INITIALIZED_MARKER}"
fi

rm -f "${HERMES_HOME}/gateway.pid"
find "${HERMES_HOME}/profiles" -mindepth 2 -maxdepth 2 -name gateway.pid -type f -delete 2>/dev/null || true

# Boot-time GBrain checks are opt-in; defaults keep startup fast.
if [ -n "${GBRAIN_DATABASE_URL:-}" ] && [ "${GBRAIN_BOOT_CHECK:-1}" != "0" ] && [ "${GBRAIN_BOOT_CHECK:-1}" != "false" ]; then
  python /app/gbrain_bootstrap.py || true
fi

# Start the shared GBrain HTTP MCP server on loopback so the public Railway
# app can proxy /mcp and the OAuth endpoints to it. Keep it in the same
# process group so tini cleans it up on shutdown.
if [ -n "${GBRAIN_DATABASE_URL:-}" ]; then
  export GBRAIN_HTTP_PORT="${GBRAIN_HTTP_PORT:-3001}"
  if [ -x /data/.hermes/home/.bun/bin/bun ] && [ -x /data/.hermes/home/.bun/install/global/node_modules/gbrain/src/cli.ts ]; then
    /data/.hermes/home/.bun/bin/bun /data/.hermes/home/.bun/install/global/node_modules/gbrain/src/cli.ts serve --http --bind 127.0.0.1 --port "${GBRAIN_HTTP_PORT}" >/data/.hermes/logs/gbrain-http.log 2>&1 &
  fi
fi

exec python /app/server.py
