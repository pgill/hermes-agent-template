#!/usr/bin/env python3
"""Refresh $HERMES_HOME/.env from Railway runtime variables.

Railway service variables exist in the container process environment on every
boot. Hermes and many tools also read a persisted .env file under HERMES_HOME.
This bridge keeps the persistent file current without making it the source of
truth for runtime secrets.

Design goals:
- idempotent on every boot
- preserve user/file-only keys that are not Railway-managed
- remove stale Railway-managed keys when the Railway variable is removed
- never print secret values
"""

from __future__ import annotations

import os
import re
from pathlib import Path

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/data/.hermes"))
ENV_FILE = HERMES_HOME / ".env"
KEYS_FILE = HERMES_HOME / "railway-env-keys.txt"

# Internal/container-only variables that should not be copied into Hermes .env.
DENY_EXACT = {
    "HOME",
    "HERMES_HOME",
    "HOSTNAME",
    "PATH",
    "PWD",
    "OLDPWD",
    "SHLVL",
    "PORT",
    "RAILWAY_ENVIRONMENT",
    "RAILWAY_ENVIRONMENT_ID",
    "RAILWAY_PROJECT_ID",
    "RAILWAY_PROJECT_NAME",
    "RAILWAY_SERVICE_ID",
    "RAILWAY_SERVICE_NAME",
    "RAILWAY_REPLICA_ID",
    "RAILWAY_STATIC_URL",
    "RAILWAY_PUBLIC_DOMAIN",
    "RAILWAY_PRIVATE_DOMAIN",
    "RAILWAY_DEPLOYMENT_ID",
    "RAILWAY_SNAPSHOT_ID",
    "NIXPACKS_METADATA",
    "UV_INDEX_URL",
    "UV_INSECURE_HOST",
    "PYTHON_VERSION",
    "PYTHONUNBUFFERED",
    "PYTHONPATH",
    "PIP_ROOT_USER_ACTION",
    "DEBIAN_FRONTEND",
    "HERMES_TUI_DIR",
    # Consumed once by start.sh when auth.json is missing. It can be large JSON
    # and may contain newlines, which do not belong in dotenv format.
    "HERMES_AUTH_JSON_BOOTSTRAP",
    # Per-session values injected by the currently running Hermes gateway/chat.
    # They are not Railway deployment configuration and would poison future boots.
    "HERMES_SESSION_CHAT_ID",
    "HERMES_SESSION_CHAT_NAME",
    "HERMES_SESSION_ID",
    "HERMES_SESSION_KEY",
    "HERMES_SESSION_MESSAGE_ID",
    "HERMES_SESSION_PLATFORM",
    "HERMES_SESSION_USER_ID",
    "HERMES_SESSION_USER_NAME",
}

DENY_PREFIXES = (
    "RAILWAY_",
    "NIXPACKS_",
)

# Copy application/runtime config by default when the name looks intentional.
ALLOW_PREFIXES = (
    "HERMES_",
    "GBRAIN_",
    "OPENROUTER_",
    "OPENAI_",
    "ANTHROPIC_",
    "DEEPSEEK_",
    "DASHSCOPE_",
    "GLM_",
    "KIMI_",
    "MINIMAX_",
    "HF_",
    "NVIDIA_",
    "ARCEEAI_",
    "STEPFUN_",
    "GEMINI_",
    "GOOGLE_",
    "NOVITA_",
    "FIREWORKS_",
    "XAI_",
    "AWS_",
    "COPILOT_",
    "GMI_",
    "OPENCODE_",
    "KILOCODE_",
    "OLLAMA_",
    "AZURE_",
    "CUSTOM_PROVIDER_",
    "PARALLEL_",
    "FIRECRAWL_",
    "TAVILY_",
    "FAL_",
    "BROWSERBASE_",
    "GITHUB_",
    "VOICE_TOOLS_",
    "HONCHO_",
    "TELEGRAM_",
    "DISCORD_",
    "SLACK_",
    "WHATSAPP_",
    "EMAIL_",
    "MATTERMOST_",
    "MATRIX_",
    "GATEWAY_",
    "ADMIN_",
    "LLM_",
    "TERMINAL_",
    "NOTION_",
)

ALLOW_EXACT = {
    "DATABASE_URL",
    "ZEROENTROPY_API_KEY",
    "VOYAGE_API_KEY",
    "EXA_API_KEY",
}

# Bare runtime keys without an app-specific prefix. These are useful in this
# container while running, but should not be persisted into Hermes .env.
DENY_BARE_EXACT = {
    "TERMINAL_ENV",
    "TERMINAL_TIMEOUT",
}

KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def parse_env(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        if KEY_RE.fullmatch(key):
            out[key] = value
    return out


def quote_env(value: str) -> str:
    if value == "":
        return ""
    if re.fullmatch(r"[A-Za-z0-9_./:@%+=,{}\-]+", value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def should_sync(key: str, value: str) -> bool:
    if not KEY_RE.fullmatch(key):
        return False
    if key in DENY_EXACT or key in DENY_BARE_EXACT or key.startswith(DENY_PREFIXES):
        return False
    if key in ALLOW_EXACT or key.startswith(ALLOW_PREFIXES):
        return True
    return False


def read_managed_keys() -> set[str]:
    if not KEYS_FILE.exists():
        return set()
    return {line.strip() for line in KEYS_FILE.read_text(encoding="utf-8").splitlines() if line.strip()}


def main() -> None:
    HERMES_HOME.mkdir(parents=True, exist_ok=True)
    existing = parse_env(ENV_FILE)
    managed_before = read_managed_keys()

    runtime = {
        key: value
        for key, value in os.environ.items()
        if should_sync(key, value)
    }

    # GBrain's canonical runtime var is GBRAIN_DATABASE_URL / DATABASE_URL. Keep
    # the friendlier Railway variable too, but make GBrain work without requiring
    # users to duplicate the value manually.
    if runtime.get("GBRAIN_SUPABASE_URL") and not runtime.get("GBRAIN_DATABASE_URL"):
        runtime["GBRAIN_DATABASE_URL"] = runtime["GBRAIN_SUPABASE_URL"]

    merged = dict(existing)

    # Remove only keys that this script previously managed and that disappeared
    # from Railway. User-created file-only keys are preserved.
    for key in managed_before - set(runtime):
        merged.pop(key, None)

    merged.update(runtime)

    grouped: dict[str, list[str]] = {"railway": [], "manual": []}
    for key in sorted(merged):
        line = f"{key}={quote_env(merged[key])}"
        if key in runtime:
            grouped["railway"].append(line)
        else:
            grouped["manual"].append(line)

    lines: list[str] = [
        "# Generated/updated on every Railway boot by sync_railway_env.py.",
        "# Edit Railway Variables for runtime-managed values; manual file-only",
        "# values are preserved below unless their key is later managed by Railway.",
        "",
    ]
    if grouped["railway"]:
        lines.append("# Railway runtime variables")
        lines.extend(grouped["railway"])
        lines.append("")
    if grouped["manual"]:
        lines.append("# Manual / dashboard values")
        lines.extend(grouped["manual"])
        lines.append("")

    ENV_FILE.write_text("\n".join(lines), encoding="utf-8")
    os.chmod(ENV_FILE, 0o600)
    KEYS_FILE.write_text("\n".join(sorted(runtime)) + ("\n" if runtime else ""), encoding="utf-8")
    print(f"[startup] synced {len(runtime)} Railway runtime variable(s) into {ENV_FILE}", flush=True)


if __name__ == "__main__":
    main()
