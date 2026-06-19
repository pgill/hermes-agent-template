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
# through to "pip" (the Dockerfile strips /opt/hermes-agent/.git) and the
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

# Seed bundled scripts to the persistent volume on first boot (or when new
# scripts are added in a template upgrade). Preserves user edits: a script
# is only copied if it doesn't already exist at the destination.
if [ -d /app/scripts ]; then
  for _script in /app/scripts/*.sh; do
    _dest="${HERMES_HOME}/scripts/$(basename "${_script}")"
    if [ ! -f "${_dest}" ]; then
      cp "${_script}" "${_dest}"
      chmod +x "${_dest}"
    fi
  done
fi

# Seed bundled skills to the persistent volume on every boot.
#
# SKILL.md is always re-rendered from the template source so {YOUR_NAME} and
# {EA_NAME} reflect the current HERMES_YOUR_NAME / HERMES_EA_NAME env vars.
# This means the vars can be set or updated any time (e.g. via Railway API
# after first boot) and take effect on the next redeploy — no race condition.
# If a var is unset the placeholder is preserved verbatim, matching how the
# course app's personalize.ts works (store the token, fill at render time).
#
# All other files (scripts, references) are copy-if-not-exists so user edits
# to those files survive redeploys.
if [ -d /app/skills ]; then
  for _skill_dir in /app/skills/*/; do
    _skill_name="$(basename "${_skill_dir}")"
    _dest_dir="${HERMES_HOME}/skills/${_skill_name}"
    mkdir -p "${_dest_dir}"
    if [ -f "${_skill_dir}SKILL.md" ]; then
      python3 -c "
import os, sys
s = sys.stdin.read()
s = s.replace('{YOUR_NAME}', os.environ.get('HERMES_YOUR_NAME', '{YOUR_NAME}'))
s = s.replace('{EA_NAME}', os.environ.get('HERMES_EA_NAME', '{EA_NAME}'))
sys.stdout.write(s)
" < "${_skill_dir}SKILL.md" > "${_dest_dir}/SKILL.md"
    fi
    find "${_skill_dir}" -mindepth 1 -not -name "SKILL.md" | while read -r _src; do
      _rel="${_src#${_skill_dir}}"
      _dest="${_dest_dir}/${_rel}"
      if [ -d "${_src}" ]; then
        mkdir -p "${_dest}"
      elif [ ! -f "${_dest}" ]; then
        cp "${_src}" "${_dest}"
      fi
    done
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

# Start the GitHub workspace backup daemon. Backs up skills, memories, config,
# and hooks to a private GitHub repo hourly. Required — BACKUP_GITHUB_TOKEN
# must be set. Runs independently of server.py so a backup error never takes
# down the gateway.
python /app/backup.py >>"${HERMES_HOME}/logs/backup.log" 2>&1 &
echo "[startup] backup daemon started (pid $!)" >&2

exec python /app/server.py
