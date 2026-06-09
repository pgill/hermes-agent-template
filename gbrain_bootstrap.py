#!/usr/bin/env python3
"""Boot-time GBrain helper for the Hermes Railway template.

Responsibilities:
- Prefer cloud-backed GBrain when GBRAIN_SUPABASE_URL is present.
- Derive GBRAIN_DATABASE_URL and GBRAIN_DIRECT_DATABASE_URL for Supabase.
- Optionally run a boot-time migration/doctor check when enabled.
- Keep startup idempotent and safe on Railway redeploys.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/data/.hermes"))
BUN = Path(os.environ.get("BUN_BIN", "/data/.hermes/home/.bun/bin/bun"))
GBRAIN = Path(os.environ.get("GBRAIN_BIN", "/data/.hermes/home/.bun/bin/gbrain"))

ENV_FILE = HERMES_HOME / ".env"


def read_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in {'"', "'"}:
            v = v[1:-1]
        out[k.strip()] = v
    return out


def write_env(path: Path, data: dict[str, str]) -> None:
    lines = [f"{k}={v}" for k, v in sorted(data.items()) if v != ""]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + ("\n" if lines else ""))
    path.chmod(0o600)


def derive_direct(url: str) -> str | None:
    if ":6543/" not in url:
        return None
    return url.replace(":6543/", ":5432/", 1)


def run(cmd: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    return subprocess.run(cmd, check=True, text=True, capture_output=True, env=merged)


def main() -> int:
    HERMES_HOME.mkdir(parents=True, exist_ok=True)

    env = read_env(ENV_FILE)
    runtime = dict(os.environ)

    # Prefer the Railway-provided variable, but also honor any preexisting file
    # value if the container already has one from a prior boot.
    supabase = runtime.get("GBRAIN_SUPABASE_URL") or env.get("GBRAIN_SUPABASE_URL") or ""
    if supabase:
        runtime["GBRAIN_SUPABASE_URL"] = supabase
        runtime.setdefault("GBRAIN_DATABASE_URL", supabase)
        if not runtime.get("GBRAIN_DIRECT_DATABASE_URL"):
            derived = derive_direct(runtime["GBRAIN_DATABASE_URL"])
            if derived:
                runtime["GBRAIN_DIRECT_DATABASE_URL"] = derived

    # Preserve manual values in .env, but refresh the Railway-managed ones.
    managed = dict(env)
    for key in [
        "GBRAIN_SUPABASE_URL",
        "GBRAIN_DATABASE_URL",
        "GBRAIN_DIRECT_DATABASE_URL",
        "ZEROENTROPY_API_KEY",
        "VOYAGE_API_KEY",
        "GITHUB_TOKEN",
    ]:
        val = runtime.get(key, "")
        if val:
            managed[key] = val
        elif key in managed and key in {"GBRAIN_SUPABASE_URL", "GBRAIN_DATABASE_URL", "GBRAIN_DIRECT_DATABASE_URL"}:
            managed.pop(key, None)

    if "GBRAIN_DATABASE_URL" not in managed and "DATABASE_URL" in runtime:
        managed["GBRAIN_DATABASE_URL"] = runtime["DATABASE_URL"]

    if managed.get("GBRAIN_DATABASE_URL") and not managed.get("GBRAIN_DIRECT_DATABASE_URL"):
        direct = derive_direct(managed["GBRAIN_DATABASE_URL"])
        if direct:
            managed["GBRAIN_DIRECT_DATABASE_URL"] = direct

    write_env(ENV_FILE, managed)

    if not managed.get("GBRAIN_DATABASE_URL"):
        return 0

    # Optional one-shot boot checks.
    migrate_on_boot = runtime.get("GBRAIN_MIGRATE_ON_BOOT", "0").lower() in {"1", "true", "yes"}
    boot_check = runtime.get("GBRAIN_BOOT_CHECK", "1").lower() not in {"0", "false", "no"}

    if migrate_on_boot and managed.get("GBRAIN_DATABASE_URL"):
        try:
            run([
                str(GBRAIN),
                "migrate",
                "--to",
                "supabase",
                "--url",
                managed["GBRAIN_DATABASE_URL"],
            ], env={
                "HOME": str(HERMES_HOME),
                "PATH": f"{BUN.parent}:{runtime.get('PATH', '')}",
                "BUN_INSTALL": str(BUN.parent.parent),
                "GBRAIN_DATABASE_URL": managed["GBRAIN_DATABASE_URL"],
                "GBRAIN_DIRECT_DATABASE_URL": managed.get("GBRAIN_DIRECT_DATABASE_URL", ""),
                "GBRAIN_SUPABASE_URL": managed.get("GBRAIN_SUPABASE_URL", ""),
            })
        except subprocess.CalledProcessError as e:
            sys.stderr.write(e.stdout)
            sys.stderr.write(e.stderr)
            raise

    if boot_check and managed.get("GBRAIN_DATABASE_URL"):
        try:
            result = run([str(GBRAIN), "doctor", "--json"], env={
                "HOME": str(HERMES_HOME),
                "PATH": f"{BUN.parent}:{runtime.get('PATH', '')}",
                "BUN_INSTALL": str(BUN.parent.parent),
                "GBRAIN_DATABASE_URL": managed["GBRAIN_DATABASE_URL"],
                "GBRAIN_DIRECT_DATABASE_URL": managed.get("GBRAIN_DIRECT_DATABASE_URL", ""),
                "GBRAIN_SUPABASE_URL": managed.get("GBRAIN_SUPABASE_URL", ""),
            })
            # Keep output succinct; the admin server logs can still show the raw JSON.
            sys.stdout.write(result.stdout)
        except subprocess.CalledProcessError as e:
            sys.stderr.write(e.stdout)
            sys.stderr.write(e.stderr)
            raise

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
