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

# Stamp the install method as "docker" so hermes treats this as an immutable
# container image, not a pip checkout. hermes's detect_install_method() reads
# $HERMES_HOME/.install_method FIRST. Without this stamp the template falls
# through to "pip" (/opt/hermes-agent is a tarball, not a git checkout) and the
# dashboard's "Update Hermes" button runs a real pip-upgrade inside the running
# container — ephemeral and desyncs Python package from pre-built UI bundles.
# Stamped unconditionally each boot so it stays correct and self-heals.
printf 'docker\n' > "${HERMES_HOME}/.install_method"

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

# Reconcile every profile's model route before any gateway starts. This keeps
# Railway restarts from restoring a stale dashboard/.env model. The guard also
# honors the Codex watchdog's active fallback state, so a restart during a 429
# window does not prematurely switch profiles back to Codex. No-op on
# deployments that don't use the Codex watchdog, and never fatal: routing
# reconciliation must not take the whole container down with it.
_model_guard="/app/boot_model_guard.py"
[ -f "${_model_guard}" ] || _model_guard="$(dirname "$0")/boot_model_guard.py"
if [ -f "${_model_guard}" ]; then
  python "${_model_guard}" || \
    echo "[startup] WARNING: model guard failed; continuing boot" >&2
fi

# Seed bundled scripts to the persistent volume on first boot (or when new
# scripts are added in a template upgrade). Preserves user edits: an existing
# script is only overwritten when it byte-matches a superseded bundled version
# listed below — meaning the user never edited it, so upgrading is safe.
# (hashes: hermes-auto-update.sh as of 5731fd5 and e4d74c1 — both no-op'd on
# Docker deployments, serviceInstanceRedeploy never rebuilds — and as of
# 0d4be20, which relied on the auto-deploy webhook after the bump push.)
_superseded_script_hashes="
673a86e1cd7ffe2760fa9ebb1bce766e2ea183335e7e7c17ea20e1faaaa6b124
0a0a2a81d1329e08bec4af1f368317afa7eb4e72145110cfe311a3a82ed7d0c4
0bed4d8f72de3dae10846330c57f9aca09ebbb78a5b75b00afba606269b95199
"
if [ -d /app/scripts ]; then
  for _script in /app/scripts/*.sh; do
    _dest="${HERMES_HOME}/scripts/$(basename "${_script}")"
    if [ ! -f "${_dest}" ]; then
      cp "${_script}" "${_dest}"
      chmod +x "${_dest}"
    elif printf '%s' "${_superseded_script_hashes}" \
        | grep -qx "$(sha256sum "${_dest}" | cut -d' ' -f1)"; then
      cp "${_script}" "${_dest}"
      chmod +x "${_dest}"
    fi
  done
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
  export PATH="/opt/bun/bin:${PATH}"
  GBRAIN_PUBLIC_URL="${GBRAIN_PUBLIC_URL:-}"
  if [ -z "${GBRAIN_PUBLIC_URL}" ] && [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    GBRAIN_PUBLIC_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
  fi
  if command -v gbrain >/dev/null 2>&1; then
    args=(serve --http --bind 127.0.0.1 --port "${GBRAIN_HTTP_PORT}" --suppress-bootstrap-token)
    if [ -n "${GBRAIN_PUBLIC_URL}" ]; then
      args+=(--public-url "${GBRAIN_PUBLIC_URL}")
    fi
    echo "[startup] starting GBrain HTTP MCP server on 127.0.0.1:${GBRAIN_HTTP_PORT}" >&2
    gbrain "${args[@]}" >/data/.hermes/logs/gbrain-http.log 2>&1 &
  else
    echo "[startup] WARNING: gbrain command not found; /mcp proxy will be unavailable" >&2
  fi
fi

# Start the backup bootstrap + watchdog. Creates the private GitHub backup
# repo on first boot and alerts via Telegram if backups go stale. The actual
# hourly mirroring/pushing is owned by the agent's github-backup skill.
# Required — BACKUP_GITHUB_TOKEN must be set. Runs independently of server.py
# so a backup error never takes down the gateway.
python /app/backup.py >>"${HERMES_HOME}/logs/backup.log" 2>&1 &
echo "[startup] backup watchdog started (pid $!)" >&2

# Run under tini because this process is PID 1 on Railway. Without an init
# reaper, orphaned Bun/bash grandchildren accumulate as zombies until the
# cgroup PID limit is exhausted, causing GBrain imports to abort with SIGABRT.
exec /usr/bin/tini -g -- python /app/server.py
