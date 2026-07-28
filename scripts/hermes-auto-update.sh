#!/bin/bash
# Checks for Hermes updates from a weekly Hermes no_agent cron (watchdog
# pattern: silent when nothing to do).
#
# Delivery: stdout from a no_agent cron is delivered to the user's home channel
# by Hermes automatically — no bot token or chat ID wiring needed in this script.
#
# Student deployments build from the course owner's public GitHub deploy repo.
# They do not need any GitHub token. Set RAILWAY_TOKEN so this cron can trigger
# a Railway rebuild when the course repo owner bumps ARG HERMES_REF; updates
# arrive automatically after that owner-side bump lands.
#
# Repo-owner deployments can also push those ARG HERMES_REF bumps themselves:
# set HERMES_UPDATE_GITHUB_TOKEN with write access to the deploy repo. Railway
# then builds normally from the GitHub change. If a repo pin already changed but
# the running image is stale, this script can trigger a Railway
# serviceInstanceDeployV2 build of the latest commit.
#
# It does not grep `hermes --version` for "Update available": that signal is
# suppressed for Docker installs in current Hermes and was phantom/stale in
# older releases.
#
# Activation: ask your agent "turn on auto-updates" or
# "check for Hermes updates every week" — it will register this script
# as a weekly Sunday 3am cron and confirm.

set -euo pipefail

UPDATE_GITHUB_TOKEN="${HERMES_UPDATE_GITHUB_TOKEN:-}"
OWNER_MODE=0
if [ -n "$UPDATE_GITHUB_TOKEN" ]; then
    OWNER_MODE=1
fi
BRANCH="${RAILWAY_GIT_BRANCH:-main}"
TMP_BASE="${TMPDIR:-/tmp}/hermes-auto-update.$$"
LATEST_RESPONSE="${TMP_BASE}.latest.json"
DOCKERFILE_RESPONSE="${TMP_BASE}.dockerfile.json"
DOCKERFILE_CONTENT="${TMP_BASE}.Dockerfile"
GITHUB_PUT_RESPONSE="${TMP_BASE}.github-put.json"
RAILWAY_RESPONSE="${TMP_BASE}.railway.json"
LATEST_TAG=""
RUNNING_REF=""
DOCKERFILE_SHA=""
REPO_REF=""

cleanup() {
    rm -f "$LATEST_RESPONSE" "$DOCKERFILE_RESPONSE" "$DOCKERFILE_CONTENT" \
        "$GITHUB_PUT_RESPONSE" "$RAILWAY_RESPONSE"
}
trap cleanup EXIT

read_latest_tag() {
    local http_code

    if ! http_code=$(curl -sS --max-time 15 -o "$LATEST_RESPONSE" -w '%{http_code}' \
        https://api.github.com/repos/NousResearch/hermes-agent/releases/latest); then
        echo "⚠️ Could not reach GitHub to check for Hermes updates."
        exit 1
    fi

    if [ "$http_code" != "200" ]; then
        echo "⚠️ Could not reach GitHub to check for Hermes updates (HTTP $http_code)."
        exit 1
    fi

    if ! LATEST_TAG=$(python3 - "$LATEST_RESPONSE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

tag = data.get("tag_name")
if not isinstance(tag, str) or not tag:
    raise SystemExit(1)

print(tag)
PY
    )
    then
        echo "⚠️ Could not parse GitHub's latest Hermes release response."
        exit 1
    fi
}

read_running_ref() {
    if [ -n "${HERMES_BAKED_REF:-}" ]; then
        RUNNING_REF="$HERMES_BAKED_REF"
        return 0
    fi

    local version_output
    version_output=$(hermes --version 2>/dev/null | head -n 1 || true)

    RUNNING_REF=$(python3 - "$version_output" <<'PY'
import re
import sys

match = re.search(r"\((\d{4}\.\d{1,2}\.\d{1,2}(?:\.\d+)?)\)", sys.argv[1])
if match:
    print("v" + match.group(1))
PY
    )
}

require_update_repo_inputs() {
    if [ -z "${RAILWAY_GIT_REPO_OWNER:-}" ]; then
        if [ "$OWNER_MODE" -eq 1 ]; then
            echo "⚠️ HERMES_UPDATE_GITHUB_TOKEN is set but RAILWAY_GIT_REPO_OWNER is not set."
            echo "This script is designed to run inside a Railway service connected to GitHub."
            exit 1
        fi
        exit 0
    fi

    if [ -z "${RAILWAY_GIT_REPO_NAME:-}" ]; then
        if [ "$OWNER_MODE" -eq 1 ]; then
            echo "⚠️ HERMES_UPDATE_GITHUB_TOKEN is set but RAILWAY_GIT_REPO_NAME is not set."
            echo "This script is designed to run inside a Railway service connected to GitHub."
            exit 1
        fi
        exit 0
    fi
}

fetch_repo_dockerfile() {
    local http_code
    local parsed
    local url

    url="https://api.github.com/repos/${RAILWAY_GIT_REPO_OWNER}/${RAILWAY_GIT_REPO_NAME}/contents/Dockerfile?ref=${BRANCH}"

    if ! http_code=$(curl -sS --max-time 15 -o "$DOCKERFILE_RESPONSE" -w '%{http_code}' \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $UPDATE_GITHUB_TOKEN" \
        "$url"); then
        echo "⚠️ Hermes update available but could not fetch Dockerfile from ${RAILWAY_GIT_REPO_OWNER}/${RAILWAY_GIT_REPO_NAME}@${BRANCH}."
        echo "Check HERMES_UPDATE_GITHUB_TOKEN and the Railway GitHub repo variables."
        exit 1
    fi

    if [ "$http_code" != "200" ]; then
        echo "⚠️ Hermes update available but could not fetch Dockerfile from ${RAILWAY_GIT_REPO_OWNER}/${RAILWAY_GIT_REPO_NAME}@${BRANCH} (HTTP $http_code)."
        echo "Check HERMES_UPDATE_GITHUB_TOKEN and the Railway GitHub repo variables."
        exit 1
    fi

    if ! parsed=$(python3 - "$DOCKERFILE_RESPONSE" "$DOCKERFILE_CONTENT" <<'PY'
import base64
import json
import re
import sys

response_path, content_path = sys.argv[1:3]
with open(response_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

sha = data.get("sha")
encoded = data.get("content")
if not isinstance(sha, str) or not isinstance(encoded, str):
    raise SystemExit(1)

content = base64.b64decode(encoded).decode("utf-8")
match = re.search(r"^ARG HERMES_REF=(\S+)\s*$", content, re.MULTILINE)
if not match:
    raise SystemExit(1)

with open(content_path, "w", encoding="utf-8") as handle:
    handle.write(content)

print(sha)
print(match.group(1))
PY
    )
    then
        echo "⚠️ Hermes update available but could not parse Dockerfile from ${RAILWAY_GIT_REPO_OWNER}/${RAILWAY_GIT_REPO_NAME}@${BRANCH}."
        exit 1
    fi

    DOCKERFILE_SHA=$(printf '%s\n' "$parsed" | sed -n '1p')
    REPO_REF=$(printf '%s\n' "$parsed" | sed -n '2p')
}

fetch_repo_dockerfile_raw() {
    local http_code
    local url

    url="https://raw.githubusercontent.com/${RAILWAY_GIT_REPO_OWNER}/${RAILWAY_GIT_REPO_NAME}/${BRANCH}/Dockerfile"

    if ! http_code=$(curl -sS --max-time 15 -o "$DOCKERFILE_CONTENT" -w '%{http_code}' "$url"); then
        echo "⚠️ Hermes update check could not fetch Dockerfile from ${RAILWAY_GIT_REPO_OWNER}/${RAILWAY_GIT_REPO_NAME}@${BRANCH}."
        exit 1
    fi

    if [ "$http_code" != "200" ]; then
        echo "⚠️ Hermes update check could not fetch Dockerfile from ${RAILWAY_GIT_REPO_OWNER}/${RAILWAY_GIT_REPO_NAME}@${BRANCH} (HTTP $http_code)."
        exit 1
    fi

    if ! REPO_REF=$(python3 - "$DOCKERFILE_CONTENT" <<'PY'
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    content = handle.read()

match = re.search(r"^ARG HERMES_REF=(\S+)\s*$", content, re.MULTILINE)
if not match:
    raise SystemExit(1)

print(match.group(1))
PY
    )
    then
        echo "⚠️ Hermes update check could not parse Dockerfile from ${RAILWAY_GIT_REPO_OWNER}/${RAILWAY_GIT_REPO_NAME}@${BRANCH}."
        exit 1
    fi
}

is_tag_newer() {
    python3 - "$1" "$2" <<'PY'
import re
import sys

latest, current = sys.argv[1:3]
pattern = re.compile(r"^v\d+(?:\.\d+){2,3}$")
if not pattern.match(current):
    raise SystemExit(2)
if not pattern.match(latest):
    raise SystemExit(1)

def parts(tag: str) -> list[int]:
    values = [int(part) for part in tag[1:].split(".")]
    return values + [0] * (4 - len(values))

raise SystemExit(0 if parts(latest) > parts(current) else 1)
PY
}

push_dockerfile_bump() {
    local latest_tag="$1"
    local dockerfile_sha="$2"
    local http_code
    local payload_file

    payload_file="${TMP_BASE}.github-put-payload.json"

    python3 - "$DOCKERFILE_CONTENT" "$payload_file" "$latest_tag" "$dockerfile_sha" "$BRANCH" <<'PY'
import base64
import json
import re
import sys

content_path, payload_path, latest_tag, dockerfile_sha, branch = sys.argv[1:6]
with open(content_path, "r", encoding="utf-8") as handle:
    content = handle.read()

new_content = re.sub(
    r"^ARG HERMES_REF=\S+\s*$",
    f"ARG HERMES_REF={latest_tag}",
    content,
    count=1,
    flags=re.MULTILINE,
)

if new_content == content:
    raise SystemExit(1)

payload = {
    "message": f"chore: bump HERMES_REF to {latest_tag} (hermes auto-update)",
    "content": base64.b64encode(new_content.encode("utf-8")).decode("ascii"),
    "sha": dockerfile_sha,
    "branch": branch,
}

with open(payload_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY

    if ! http_code=$(curl -sS --max-time 15 -o "$GITHUB_PUT_RESPONSE" -w '%{http_code}' \
        -X PUT \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $UPDATE_GITHUB_TOKEN" \
        -H "Content-Type: application/json" \
        --data @"$payload_file" \
        "https://api.github.com/repos/${RAILWAY_GIT_REPO_OWNER}/${RAILWAY_GIT_REPO_NAME}/contents/Dockerfile"); then
        rm -f "$payload_file"
        echo "⚠️ Hermes update available but Dockerfile bump failed (HTTP curl-error)."
        exit 1
    fi

    rm -f "$payload_file"

    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        echo "⚠️ Hermes update available but Dockerfile bump failed (HTTP $http_code)."
        exit 1
    fi
}

require_railway_inputs() {
    if [ -z "${RAILWAY_TOKEN:-}" ]; then
        echo "⚠️ Hermes update needs a Railway rebuild but RAILWAY_TOKEN is not set."
        echo "Add it in Railway → Variables (workspace-scoped token from railway.com/account/tokens)."
        exit 1
    fi

    if [ -z "${RAILWAY_SERVICE_ID:-}" ] || [ -z "${RAILWAY_ENVIRONMENT_ID:-}" ]; then
        if [ -z "${RAILWAY_SERVICE_ID:-}" ]; then
            echo "⚠️ Hermes update needs a Railway rebuild but RAILWAY_SERVICE_ID is not set."
        else
            echo "⚠️ Hermes update needs a Railway rebuild but RAILWAY_ENVIRONMENT_ID is not set."
        fi
        echo "This script is designed to run inside a Railway service."
        exit 1
    fi
}

trigger_railway_build() {
    local http_code
    local payload_file

    require_railway_inputs

    payload_file="${TMP_BASE}.railway-payload.json"
    python3 - "$payload_file" "$RAILWAY_SERVICE_ID" "$RAILWAY_ENVIRONMENT_ID" <<'PY'
import json
import sys

payload_path, service_id, environment_id = sys.argv[1:4]
payload = {
    "query": (
        "mutation($serviceId: String!, $environmentId: String!) { "
        "serviceInstanceDeployV2(serviceId: $serviceId, environmentId: $environmentId) "
        "}"
    ),
    "variables": {
        "serviceId": service_id,
        "environmentId": environment_id,
    },
}

with open(payload_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY

    if ! http_code=$(curl -sS --max-time 15 -o "$RAILWAY_RESPONSE" -w '%{http_code}' \
        -X POST https://backboard.railway.com/graphql/v2 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $RAILWAY_TOKEN" \
        --data @"$payload_file"); then
        rm -f "$payload_file"
        echo "⚠️ Hermes update found but Railway rebuild trigger failed (HTTP curl-error)."
        exit 1
    fi

    rm -f "$payload_file"

    if [ "$http_code" != "200" ] || python3 - "$RAILWAY_RESPONSE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

raise SystemExit(0 if data.get("errors") else 1)
PY
    then
        echo "⚠️ Hermes update found but Railway rebuild trigger failed (HTTP $http_code)."
        echo "Check your RAILWAY_TOKEN in Railway → Variables."
        exit 1
    fi
}

read_running_ref

require_update_repo_inputs

if [ "$OWNER_MODE" -eq 1 ]; then
    fetch_repo_dockerfile
else
    fetch_repo_dockerfile_raw
fi

if [[ "$REPO_REF" =~ ^v[0-9.]+$ ]]; then
    if [ -n "$RUNNING_REF" ] && [ "$RUNNING_REF" != "$REPO_REF" ]; then
        trigger_railway_build
        echo "🔄 Hermes update: deploy repo now pins ${REPO_REF} (this agent is on ${RUNNING_REF}) — rebuilding now; back online on the new version in ~10 minutes."
        exit 0
    fi

    if [ "$OWNER_MODE" -ne 1 ]; then
        exit 0
    fi

    read_latest_tag

    set +e
    is_tag_newer "$LATEST_TAG" "$REPO_REF"
    TAG_COMPARE=$?
    set -e

    if [ "$TAG_COMPARE" -eq 0 ]; then
        push_dockerfile_bump "$LATEST_TAG" "$DOCKERFILE_SHA"
        echo "🔄 Hermes ${RUNNING_REF:-unknown} → ${LATEST_TAG}: pushed Dockerfile bump to ${RAILWAY_GIT_REPO_OWNER}/${RAILWAY_GIT_REPO_NAME}@${BRANCH}. Railway is building the new image now; your agent restarts on the new version in ~10 minutes. Next weekly check verifies it took."
        exit 0
    fi

    exit 0
fi

if [ "$REPO_REF" = "main" ]; then
    read_latest_tag

    if [ -n "$RUNNING_REF" ] && [ "$RUNNING_REF" != "$LATEST_TAG" ]; then
        trigger_railway_build
        echo "🔄 Hermes update: triggered rebuild from latest commit (deploy repo tracks main)."
        exit 0
    fi

    exit 0
fi

if [ "$OWNER_MODE" -ne 1 ]; then
    exit 0
fi

echo "⚠️ HERMES_REF is pinned to an unrecognized ref: ${REPO_REF}."
exit 1
