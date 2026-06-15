#!/usr/bin/env python3
"""
GitHub workspace backup daemon for the hermes-agent Railway template.

Runs as a background process alongside server.py. When BACKUP_GITHUB_TOKEN
is set it:
  1. (first boot) bootstraps a private GitHub backup repo, writes a safe
     .gitignore that excludes secrets and large ephemeral dirs, and does
     the initial commit + push.
  2. Runs an hourly git commit + push.
  3. Nightly (01:xx UTC) checks backup recency; sends a Telegram alert if
     the last push is stale and BACKUP_TELEGRAM_CHAT_ID is configured.

Environment variables:
  BACKUP_GITHUB_TOKEN       GitHub personal access token (repo scope). Required.
  BACKUP_REPO               owner/name of the backup repo (created if absent).
                            Defaults to <github_username>/hermes-backup.
  BACKUP_TELEGRAM_CHAT_ID   Telegram chat ID for stale-backup alerts (optional).
  TELEGRAM_BOT_TOKEN        Telegram bot token — also read from HERMES_HOME/.env.
"""

import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/data/.hermes"))
MARKER_FILE = HERMES_HOME / ".backup_last_success"
BOOTSTRAP_MARKER = HERMES_HOME / ".backup_bootstrapped"

# Files/dirs to never commit — secrets, large caches, ephemeral runtime state.
_GITIGNORE = """\
# SECURITY: never commit credentials or OAuth tokens
.env
profiles/*/.env
auth.json
.install_method

# Large / ephemeral dirs
logs/
sessions/
image_cache/
audio_cache/
pairing/
caches/

# Runtime state
*.pid
*.sock
*.tmp
.backup_last_success
"""

POLL_INTERVAL_S = 300       # check every 5 min — fine-grained enough to hit hour/day windows
BACKUP_INTERVAL_S = 3600    # push every hour
VERIFY_HOUR_UTC = 1         # run nightly verify at 01:xx UTC
STALE_THRESHOLD_H = 25      # alert if no successful backup in this many hours


def _env(key: str) -> str:
    val = os.environ.get(key, "")
    if val:
        return val
    env_file = HERMES_HOME / ".env"
    if env_file.exists():
        for line in env_file.read_text(errors="replace").splitlines():
            if line.startswith(f"{key}="):
                return line[len(key) + 1:].strip().strip('"').strip("'")
    return ""


def _github_api(
    path: str,
    token: str,
    method: str = "GET",
    data: dict | None = None,
) -> dict | None:
    url = f"https://api.github.com{path}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "Content-Type": "application/json",
        "User-Agent": "hermes-agent-template/1.0",
    }
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        print(f"[backup] GitHub API {method} {path} → {e.code}: {e.read().decode(errors='replace')}", flush=True)
        return None
    except Exception as exc:
        print(f"[backup] GitHub API error: {exc}", flush=True)
        return None


def _git(*args: str) -> tuple[int, str]:
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    result = subprocess.run(
        ["git", *args],
        capture_output=True,
        text=True,
        cwd=str(HERMES_HOME),
        env=env,
    )
    return result.returncode, (result.stdout + result.stderr).strip()


def _git_ok(*args: str) -> str:
    rc, out = _git(*args)
    if rc != 0:
        raise RuntimeError(f"git {' '.join(args)}: {out}")
    return out


def bootstrap(token: str, repo_name: str) -> bool:
    """Create GitHub repo, configure git remote, do first push. Returns True on success."""
    print(f"[backup] bootstrapping backup → {repo_name}", flush=True)

    user = _github_api("/user", token=token)
    if not user:
        print("[backup] ERROR: GitHub authentication failed", flush=True)
        return False
    username = user["login"]

    if "/" not in repo_name:
        repo_name = f"{username}/{repo_name}"
    owner, name = repo_name.split("/", 1)

    existing = _github_api(f"/repos/{owner}/{name}", token=token)
    if existing is None:
        print(f"[backup] creating private repo {repo_name}", flush=True)
        created = _github_api("/user/repos", token=token, method="POST", data={
            "name": name,
            "private": True,
            "description": "Hermes agent workspace backup (auto-created by hermes-agent-template)",
            "auto_init": True,
        })
        if not created:
            print("[backup] ERROR: could not create GitHub repo", flush=True)
            return False
        print(f"[backup] created: {created['html_url']}", flush=True)
        time.sleep(2)
    else:
        print(f"[backup] using existing repo: {existing['html_url']}", flush=True)

    # Write .gitignore (secrets excluded) — never overwrite if user customised it
    gitignore = HERMES_HOME / ".gitignore"
    if not gitignore.exists():
        gitignore.write_text(_GITIGNORE)

    _git("config", "--global", "user.email", "hermes-backup@railway.app")
    _git("config", "--global", "user.name", "Hermes Backup")

    if not (HERMES_HOME / ".git").exists():
        _git_ok("init")

    remote_url = f"https://{token}@github.com/{repo_name}.git"
    rc, _ = _git("remote", "get-url", "origin")
    if rc != 0:
        _git_ok("remote", "add", "origin", remote_url)
    else:
        _git_ok("remote", "set-url", "origin", remote_url)

    _git("add", "-A")
    rc, out = _git("commit", "-m", "chore: initial hermes workspace backup")
    if rc != 0 and "nothing to commit" not in out:
        print(f"[backup] initial commit: {out}", flush=True)

    try:
        _git_ok("push", "--force", "origin", "HEAD:main")
        print("[backup] initial push succeeded", flush=True)
    except RuntimeError as exc:
        print(f"[backup] WARNING: initial push failed ({exc}) — will retry next hour", flush=True)

    MARKER_FILE.write_text(str(int(time.time())))
    BOOTSTRAP_MARKER.write_text(repo_name)
    return True


def backup_now(token: str) -> bool:
    """Commit and push workspace changes. Returns True on success."""
    if not BOOTSTRAP_MARKER.exists():
        return False
    repo_name = BOOTSTRAP_MARKER.read_text().strip()

    # Keep the remote URL fresh in case the token rotated
    remote_url = f"https://{token}@github.com/{repo_name}.git"
    _git("remote", "set-url", "origin", remote_url)

    _git("add", "-A")
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rc, out = _git("commit", "-m", f"chore: backup {ts}")
    if rc != 0 and "nothing to commit" not in out:
        print(f"[backup] commit: {out}", flush=True)

    try:
        _git_ok("push", "origin", "HEAD:main")
        MARKER_FILE.write_text(str(int(time.time())))
        print(f"[backup] pushed at {ts}", flush=True)
        return True
    except RuntimeError as exc:
        print(f"[backup] ERROR: push failed: {exc}", flush=True)
        return False


def _telegram(bot_token: str, chat_id: str, text: str) -> None:
    data = json.dumps({"chat_id": chat_id, "text": text, "parse_mode": "Markdown"}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{bot_token}/sendMessage",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as exc:
        print(f"[backup] Telegram notify error: {exc}", flush=True)


def verify(token: str) -> None:
    """Check backup recency; send Telegram alert if stale."""
    if not MARKER_FILE.exists():
        stale = True
        age_str = "never"
    else:
        last = int(MARKER_FILE.read_text().strip())
        age_h = (time.time() - last) / 3600
        stale = age_h > STALE_THRESHOLD_H
        age_str = f"{age_h:.1f}h ago"

    if not stale:
        print(f"[backup] verify OK — last backup {age_str}", flush=True)
        return

    print(f"[backup] STALE ({age_str}) — sending alert", flush=True)

    bot_token = _env("TELEGRAM_BOT_TOKEN") or _env("TELEGRAM_TOKEN")
    chat_id = _env("BACKUP_TELEGRAM_CHAT_ID")
    if bot_token and chat_id:
        repo = BOOTSTRAP_MARKER.read_text().strip() if BOOTSTRAP_MARKER.exists() else "unknown"
        msg = (
            f"⚠️ *Hermes backup alert*\n\n"
            f"Last successful backup to `{repo}`: {age_str}\n\n"
            "The workspace backup has not run recently. "
            "Check Railway logs for details."
        )
        _telegram(bot_token, chat_id, msg)
    else:
        print("[backup] no TELEGRAM_BOT_TOKEN/BACKUP_TELEGRAM_CHAT_ID — skipping notify", flush=True)


def main() -> None:
    token = _env("BACKUP_GITHUB_TOKEN")
    if not token:
        print(
            "[backup] ERROR: BACKUP_GITHUB_TOKEN is not set. "
            "Workspace backups are required — add a GitHub personal access token "
            "(repo scope) as the BACKUP_GITHUB_TOKEN Railway variable and redeploy.",
            flush=True,
        )
        # Retry every 10 min in case the variable is added without a full redeploy.
        while not token:
            time.sleep(600)
            token = _env("BACKUP_GITHUB_TOKEN")
        print("[backup] BACKUP_GITHUB_TOKEN found — starting backup", flush=True)

    repo_name = os.environ.get("BACKUP_REPO", "hermes-backup")

    if not BOOTSTRAP_MARKER.exists():
        if not bootstrap(token, repo_name):
            print("[backup] bootstrap failed — will retry on next container start", flush=True)
            return

    print(f"[backup] daemon started (hourly push, nightly verify at {VERIFY_HOUR_UTC:02d}:xx UTC)", flush=True)

    last_backup = time.time()
    last_verify_day: int | None = None

    while True:
        time.sleep(POLL_INTERVAL_S)

        # Re-read token each cycle in case Railway var was updated
        token = _env("BACKUP_GITHUB_TOKEN")
        if not token:
            continue

        now = time.time()
        now_utc = datetime.now(timezone.utc)

        if now - last_backup >= BACKUP_INTERVAL_S:
            if backup_now(token):
                last_backup = now

        if now_utc.hour == VERIFY_HOUR_UTC and last_verify_day != now_utc.day:
            last_verify_day = now_utc.day
            verify(token)


if __name__ == "__main__":
    main()
