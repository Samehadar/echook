"""Invoker detection for the audio-hooks runner.

Lives in its own module so ``user_preferences.py`` can ask "which IDE/CLI
invoked us?" without circularly importing ``hook_runner``.

Detection priority (first match wins):

1. ``--invoker <name>`` CLI flag in ``sys.argv`` — baked into the Codex
   ``hooks.json`` template by ``audio-hooks install --codex`` because Codex
   sets no env var we could detect by. Also handy for tests.
2. ``CURSOR_VERSION`` env var — always set by Cursor's third-party-hooks
   bridge when it invokes a hook (see cursor.com/docs/hooks).
3. ``CLAUDE_PLUGIN_DATA`` / ``CLAUDE_PLUGIN_ROOT`` env vars — set by Claude
   Code's plugin loader when it invokes a hook.
4. Fallback: ``"unknown"`` — direct CLI use, ad-hoc tests.
"""
from __future__ import annotations

import os
import sys
from typing import List, Optional

_VALID_INVOKERS = {"codex", "cursor", "claude-code"}
_invoker_cache: Optional[str] = None


def _parse_invoker_arg(argv: List[str]) -> Optional[str]:
    """Return the ``--invoker <name>`` value from argv, or None."""
    for i, a in enumerate(argv):
        if a == "--invoker" and i + 1 < len(argv):
            name = argv[i + 1]
            return name if name in _VALID_INVOKERS else None
        if a.startswith("--invoker="):
            name = a.split("=", 1)[1]
            return name if name in _VALID_INVOKERS else None
    return None


def detect_invoker() -> str:
    """Return ``"codex"`` / ``"cursor"`` / ``"claude-code"`` / ``"unknown"``."""
    arg = _parse_invoker_arg(sys.argv)
    if arg:
        return arg
    if os.environ.get("CURSOR_VERSION"):
        return "cursor"
    if os.environ.get("CLAUDE_PLUGIN_DATA") or os.environ.get("CLAUDE_PLUGIN_ROOT"):
        return "claude-code"
    return "unknown"


def get_invoker() -> str:
    """Cached wrapper. A single hook invocation can call this dozens of times."""
    global _invoker_cache
    if _invoker_cache is None:
        _invoker_cache = detect_invoker()
    return _invoker_cache


def _reset_cache() -> None:
    """Test-only: clear the cache so a unit test can vary invoker between calls."""
    global _invoker_cache
    _invoker_cache = None


def strip_invoker_args(argv: List[str]) -> List[str]:
    """Return ``argv`` with ``--invoker <name>`` (or ``--invoker=<name>``) removed."""
    out: List[str] = []
    skip_next = False
    for a in argv:
        if skip_next:
            skip_next = False
            continue
        if a == "--invoker":
            skip_next = True
            continue
        if a.startswith("--invoker="):
            continue
        out.append(a)
    return out
