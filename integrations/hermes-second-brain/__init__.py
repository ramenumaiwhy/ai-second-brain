"""Hermes hook that saves each completed turn to AI Second Brain."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


def _text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return _text(value.get("text", value.get("content", "")))
    if isinstance(value, list):
        parts = [_text(item) for item in value]
        return "\n".join(part for part in parts if part)
    return str(value)


def _repo_dir() -> Path:
    override = os.environ.get("AI_SECOND_BRAIN_REPO_DIR", "").strip()
    if override:
        return Path(override).expanduser()
    # The installed user plugin is a symlink to this repository directory.
    return Path(__file__).resolve().parents[2]


def _on_post_llm_call(**kwargs: Any) -> None:
    user_message = _text(kwargs.get("user_message")).strip()
    assistant_response = _text(kwargs.get("assistant_response")).strip()
    session_id = str(kwargs.get("session_id") or "").strip()
    if not session_id or not user_message or not assistant_response:
        return

    script = _repo_dir() / "scripts" / "save-hermes-turn.py"
    if not script.is_file():
        raise RuntimeError(f"Hermes Second Brain writer not found: {script}")

    payload = {
        "session_id": session_id,
        "turn_id": str(kwargs.get("turn_id") or "").strip(),
        "platform": str(kwargs.get("platform") or "hermes").strip(),
        "model": str(kwargs.get("model") or "").strip(),
        "user_message": user_message,
        "assistant_response": assistant_response,
    }
    result = subprocess.run(
        [sys.executable, str(script)],
        input=json.dumps(payload, ensure_ascii=False),
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        raise RuntimeError(f"Hermes Second Brain save failed: {detail}")


def register(ctx: Any) -> None:
    ctx.register_hook("post_llm_call", _on_post_llm_call)
