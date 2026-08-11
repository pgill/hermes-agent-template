#!/usr/bin/env python3
"""Reconcile every Hermes profile's model route before gateways start.

The Codex rate-limit watchdog owns temporary fallback state. On normal boots,
all profiles are pinned to the configured primary. If Railway restarts during
an active rate-limit window, all profiles stay on the configured fallback.
"""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from pathlib import Path
from typing import Any

import yaml

PRIMARY_MODEL = os.environ.get("CODEX_WATCHDOG_PRIMARY_MODEL", "gpt-5.6-sol")
PRIMARY_PROVIDER = os.environ.get("CODEX_WATCHDOG_PRIMARY_PROVIDER", "openai-codex")
FALLBACK_MODEL = os.environ.get(
    "CODEX_WATCHDOG_FALLBACK_MODEL", "anthropic/claude-sonnet-5"
)
FALLBACK_PROVIDER = os.environ.get("CODEX_WATCHDOG_FALLBACK_PROVIDER", "openrouter")


def desired_route(root: Path) -> tuple[str, str, str]:
    state_path = root / "cache" / "codex_ratelimit_watchdog_state.json"
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        state = {}

    if state.get("mode") == "fallback":
        return FALLBACK_MODEL, FALLBACK_PROVIDER, "fallback"
    return PRIMARY_MODEL, PRIMARY_PROVIDER, "primary"


def profile_configs(root: Path) -> list[tuple[str, Path]]:
    configs = [("default", root / "config.yaml")]
    profiles_dir = root / "profiles"
    if profiles_dir.is_dir():
        for profile_dir in sorted(p for p in profiles_dir.iterdir() if p.is_dir()):
            configs.append((profile_dir.name, profile_dir / "config.yaml"))
    return configs


def load_config(path: Path) -> dict[str, Any]:
    try:
        loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (yaml.YAMLError, OSError) as exc:
        raise RuntimeError(f"cannot read {path}: {exc}") from exc
    if loaded is None:
        return {}
    if not isinstance(loaded, dict):
        raise RuntimeError(f"config is not a mapping: {path}")
    return loaded


def atomic_write_yaml(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            yaml.safe_dump(data, handle, sort_keys=False, default_flow_style=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def reconcile(root: Path, *, dry_run: bool = False) -> tuple[str, list[str]]:
    model, provider, mode = desired_route(root)
    changed: list[str] = []

    for profile, config_path in profile_configs(root):
        config = load_config(config_path)
        model_config = config.get("model")
        if not isinstance(model_config, dict):
            model_config = {}
        else:
            model_config = dict(model_config)

        if (
            model_config.get("default") == model
            and model_config.get("provider") == provider
        ):
            continue

        model_config["default"] = model
        model_config["provider"] = provider
        config["model"] = model_config
        if not dry_run:
            atomic_write_yaml(config_path, config)
        changed.append(profile)

    return mode, changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(os.environ.get("HERMES_HOME", "/data/.hermes")),
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    try:
        mode, changed = reconcile(args.root.expanduser().resolve(), dry_run=args.dry_run)
    except RuntimeError as exc:
        print(f"[startup] ERROR: model guard failed: {exc}", flush=True)
        return 1

    action = "would reconcile" if args.dry_run else "reconciled"
    if changed:
        print(
            f"[startup] model guard ({mode}) {action} {len(changed)} profile(s): "
            + ", ".join(changed),
            flush=True,
        )
    else:
        print(f"[startup] model guard ({mode}) verified all profiles", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
