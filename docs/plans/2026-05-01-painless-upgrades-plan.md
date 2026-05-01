# Painless Upgrades (5.1.5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship audio-hooks 5.1.5 such that existing users never lose configuration on upgrade, new keys auto-merge non-destructively, default flips become CI-enforced policy violations, and the entire upgrade is one JSON CLI command.

**Architecture:** New `hooks/user_preferences.py` module owns ALL access to `user_preferences.json` (path resolution + load with auto-migration + save with auto-backup + restore). Both `hooks/hook_runner.py` and `bin/audio-hooks.py` consolidate onto it via lazy `get_prefs()` singleton. New `audio-hooks upgrade` wraps `claude plugin update`/`uninstall+install` with `--keep-data`. New `audio-hooks backup *` subcommands give AI explicit control over backups. New `config/_defaults_baseline.json` + `tests/test_defaults_stability.py` enforce the no-default-flip policy at CI.

**Tech Stack:** Python 3.6+, stdlib only (json, os, fcntl/msvcrt, pathlib, subprocess, unittest). No new dependencies.

**Spec:** `docs/specs/2026-05-01-painless-upgrades-design.md` (commit `2c5d7b5`).

**Commits per phase (user-confirmed):** 1 commit per phase, 5 commits total on a feature branch tagged `v5.1.5`. Tasks within a phase do NOT commit individually; only the final task of each phase commits.

---

## Phase Overview

| Phase | Commit | Scope |
|---|---|---|
| 1 | `feat(prefs): add UserPreferences class as single source of truth` | New `hooks/user_preferences.py` + 3 new test files. NO call-site changes — class lives next to existing helpers, both work, all tests green. |
| 2 | `refactor(prefs): migrate hook_runner + audio-hooks CLI onto UserPreferences` | Delete duplicated helpers + module-level globals; thread `get_prefs()` through every call site. Existing tests still pass. |
| 3 | `feat(cli): audio-hooks upgrade + backup subcommands` | New CLI verbs; manifest output extensions. |
| 4 | `fix(defaults): revert 5.1.4 default flips + add stability test baseline` | `subagent_stop` / `permission_denied` / `task_created` back to false; new `_defaults_baseline.json`; new `test_defaults_stability.py`. |
| 5 | `chore(release): v5.1.5 — painless upgrades` | Plugin layout sync, CHANGELOG / README / SKILL / `plugin.json` bumps, release tag. |

---

## Pre-Flight (Run Once)

- [ ] **Step 0.1: Verify clean working tree**

```bash
cd D:/github_repository/claude-code-audio-hooks && git status --short
```
Expected: empty output. If not, stash or commit prior work first.

- [ ] **Step 0.2: Create feature branch**

```bash
git checkout -b feat/painless-upgrades-5.1.5
```
Expected: `Switched to a new branch 'feat/painless-upgrades-5.1.5'`.

- [ ] **Step 0.3: Verify baseline tests green**

```bash
python -m pytest tests/ -q
```
Expected: `40 passed` (13 cursor_bridge + 25 statusline + 2 regression). If anything fails, stop and fix before starting Phase 1.

---

# Phase 1 — `UserPreferences` class

**Files:**
- Create: `hooks/user_preferences.py`
- Create: `tests/test_user_preferences.py`
- Create: `tests/test_migration.py`
- Create: `tests/test_backups.py`

**Phase commit message:**
```
feat(prefs): add UserPreferences class as single source of truth

New hooks/user_preferences.py owns path resolution, load (auto-migrate),
save (auto-backup), backup management, and diff-from-default reporting.
This commit only ADDS the class + tests — no call-site migration yet, so
existing hook_runner.py and bin/audio-hooks.py continue to work via
their current helpers.

The class follows the spec at docs/specs/2026-05-01-painless-upgrades-design.md:
- Lazy get_prefs() singleton (no import-time side effects)
- 6-level path resolution chain (env vars → plugin layout → shared dir
  → cursor-native dir → legacy temp), pinning the 5.1.4 anti-stranding
  shared-dir branch with a regression test
- Migration on load with deep-merge-missing semantics; lists are atomic;
  scalar-vs-container mismatch resets to template default
- Atomic write via os.replace + cross-platform file lock
  (fcntl.flock POSIX, msvcrt.locking Windows) on .user_prefs.lock
- Dual-location backups: sibling .bak (last good) + external timestamped
  history at ~/.claude-audio-hooks-backups/<plugin_id>/<ts>.json
  (rotation: keep 20, dedup byte-identical content)
- ISO-8601 timestamp IDs with millisecond suffix; round-trippable
  filename<->id conversion for Windows compatibility (replaces : with -)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 1.1 — Module skeleton + path resolution

**Files:**
- Create: `hooks/user_preferences.py`
- Create: `tests/test_user_preferences.py`

- [ ] **Step 1.1.1: Write failing tests for path resolution chain**

Create `tests/test_user_preferences.py` with:

```python
"""Tests for UserPreferences path resolution chain.

Pins the 6-level priority documented in the spec:
  1. CLAUDE_PLUGIN_DATA env
  2. CLAUDE_AUDIO_HOOKS_DATA env
  3. plugin-cache layout (script under <plugin>/.claude-plugin/plugin.json)
  4. shared dir ~/.claude/plugins/data/audio-hooks-chanmeng-audio-hooks/
     IF user_preferences.json exists there (5.1.4 anti-stranding fix —
     regression-tested explicitly)
  5. cursor-native dir ~/.cursor/audio-hooks-data/
     IF user_preferences.json exists there
  6. legacy temp dir <TEMP>/claude_audio_hooks_queue/
"""

from __future__ import annotations

import importlib.util
import json
import os
import platform
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Optional

REPO = Path(__file__).resolve().parent.parent
MODULE_PATH = REPO / "hooks" / "user_preferences.py"


def _load_module():
    """Import user_preferences.py fresh each test for isolation."""
    sys.modules.pop("user_preferences", None)
    spec = importlib.util.spec_from_file_location("user_preferences", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestPathResolution(unittest.TestCase):
    def setUp(self):
        self._saved = {
            k: os.environ.pop(k, None)
            for k in (
                "CLAUDE_PLUGIN_DATA",
                "CLAUDE_AUDIO_HOOKS_DATA",
                "CLAUDE_PLUGIN_ROOT",
                "CURSOR_VERSION",
            )
        }

    def tearDown(self):
        for k, v in self._saved.items():
            if v is not None:
                os.environ[k] = v
            else:
                os.environ.pop(k, None)

    def test_claude_plugin_data_wins(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["CLAUDE_PLUGIN_DATA"] = td
            mod = _load_module()
            prefs = mod.UserPreferences(REPO)
            self.assertEqual(str(prefs.data_dir), td)
            self.assertEqual(str(prefs.config_path), str(Path(td) / "user_preferences.json"))

    def test_audio_hooks_data_when_no_plugin_data(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["CLAUDE_AUDIO_HOOKS_DATA"] = td
            mod = _load_module()
            prefs = mod.UserPreferences(REPO)
            self.assertEqual(str(prefs.data_dir), td)

    def test_shared_dir_used_when_user_prefs_exists_there(self):
        """5.1.4 anti-stranding regression test."""
        with tempfile.TemporaryDirectory() as fake_home:
            shared = (
                Path(fake_home)
                / ".claude" / "plugins" / "data"
                / "audio-hooks-chanmeng-audio-hooks"
            )
            shared.mkdir(parents=True)
            (shared / "user_preferences.json").write_text(
                '{"audio_theme": "custom"}', encoding="utf-8"
            )
            mod = _load_module()
            original_home = mod.Path.home
            try:
                mod.Path.home = staticmethod(lambda: mod.Path(fake_home))
                prefs = mod.UserPreferences(REPO)
                self.assertEqual(prefs.data_dir, shared)
            finally:
                mod.Path.home = original_home

    def test_cursor_native_used_when_shared_absent(self):
        with tempfile.TemporaryDirectory() as fake_home:
            cursor = Path(fake_home) / ".cursor" / "audio-hooks-data"
            cursor.mkdir(parents=True)
            (cursor / "user_preferences.json").write_text(
                '{"audio_theme": "default"}', encoding="utf-8"
            )
            mod = _load_module()
            original_home = mod.Path.home
            try:
                mod.Path.home = staticmethod(lambda: mod.Path(fake_home))
                prefs = mod.UserPreferences(REPO)
                self.assertEqual(prefs.data_dir, cursor)
            finally:
                mod.Path.home = original_home

    def test_legacy_temp_fallback(self):
        with tempfile.TemporaryDirectory() as fake_home:
            mod = _load_module()
            original_home = mod.Path.home
            try:
                mod.Path.home = staticmethod(lambda: mod.Path(fake_home))
                prefs = mod.UserPreferences(REPO)
                resolved = prefs.data_dir
                self.assertTrue(
                    str(resolved).endswith("claude_audio_hooks_queue"),
                    f"Expected legacy temp fallback, got {resolved}",
                )
            finally:
                mod.Path.home = original_home

    def test_queue_dir_and_log_dir_subdirs_of_data_dir(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["CLAUDE_PLUGIN_DATA"] = td
            mod = _load_module()
            prefs = mod.UserPreferences(REPO)
            self.assertEqual(prefs.queue_dir, Path(td) / "queue")
            self.assertEqual(prefs.log_dir, Path(td) / "logs")

    def test_legacy_temp_data_dir_does_not_double_nest_queue(self):
        """When fallback returns .../claude_audio_hooks_queue, queue_dir
        must not become .../claude_audio_hooks_queue/queue (preserves
        v5.1.3 layout for legacy script-install users)."""
        with tempfile.TemporaryDirectory() as fake_home:
            mod = _load_module()
            original_home = mod.Path.home
            try:
                mod.Path.home = staticmethod(lambda: mod.Path(fake_home))
                prefs = mod.UserPreferences(REPO)
                self.assertTrue(str(prefs.queue_dir).endswith("claude_audio_hooks_queue"))
                self.assertFalse(str(prefs.queue_dir).endswith("claude_audio_hooks_queue/queue"))
                self.assertFalse(str(prefs.queue_dir).endswith("claude_audio_hooks_queue\\queue"))
            finally:
                mod.Path.home = original_home


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 1.1.2: Verify all tests fail**

```bash
python -m pytest tests/test_user_preferences.py -v
```
Expected: collection error (module doesn't exist yet) — all tests in `TestPathResolution` listed as `ERROR` or fail at import.

- [ ] **Step 1.1.3: Create `hooks/user_preferences.py` skeleton with path resolution**

```python
"""UserPreferences — single source of truth for user_preferences.json access.

This module is intentionally side-effect-free at import time. All filesystem
probing happens lazily on first use of a UserPreferences instance. Both
hook_runner.py and bin/audio-hooks.py acquire an instance via get_prefs()
(lazy module-level singleton) so they share path resolution, load
semantics, and backup state.

See docs/specs/2026-05-01-painless-upgrades-design.md for the design.
"""

from __future__ import annotations

import os
import platform
from pathlib import Path
from typing import Any, Dict, List, Optional


class UserPreferences:
    """Single source of truth for user_preferences.json access.

    Owns path resolution, load (with auto-migration), save (with auto-backup),
    backup management, and diff-from-default reporting.
    """

    PLUGIN_ID = "audio-hooks-chanmeng-audio-hooks"
    EXTERNAL_BACKUP_DIRNAME = ".claude-audio-hooks-backups"
    EXTERNAL_BACKUP_KEEP = 20
    LOCK_TIMEOUT_SECONDS = 5

    def __init__(self, project_dir: Path, *, script_path: Optional[Path] = None):
        self.project_dir = Path(project_dir)
        self._script_path = Path(script_path) if script_path else Path(__file__).resolve()
        self._cached_data_dir: Optional[Path] = None

    # ------------------------------------------------------------------
    # Path resolution
    # ------------------------------------------------------------------

    @property
    def data_dir(self) -> Path:
        if self._cached_data_dir is not None:
            return self._cached_data_dir
        self._cached_data_dir = self._resolve_data_dir()
        return self._cached_data_dir

    @property
    def config_path(self) -> Path:
        return self.data_dir / "user_preferences.json"

    @property
    def queue_dir(self) -> Path:
        d = self.data_dir
        # The legacy temp fallback is itself named claude_audio_hooks_queue;
        # don't double-nest by appending another /queue.
        if d.name == "claude_audio_hooks_queue":
            return d
        return d / "queue"

    @property
    def log_dir(self) -> Path:
        return self.data_dir / "logs"

    def _resolve_data_dir(self) -> Path:
        """Six-level priority chain. See spec for rationale."""
        v = os.environ.get("CLAUDE_PLUGIN_DATA")
        if v:
            return Path(v)
        v = os.environ.get("CLAUDE_AUDIO_HOOKS_DATA")
        if v:
            return Path(v)
        if self._is_running_from_plugin():
            return self._plugin_cache_data_dir()
        home = Path.home()
        shared = home / ".claude" / "plugins" / "data" / self.PLUGIN_ID
        if (shared / "user_preferences.json").exists():
            return shared
        cursor_native = home / ".cursor" / "audio-hooks-data"
        if (cursor_native / "user_preferences.json").exists():
            return cursor_native
        if platform.system() == "Windows":
            base = Path(os.environ.get("TEMP", os.environ.get("TMP", "C:/Windows/Temp")))
        else:
            base = Path("/tmp")
        return base / "claude_audio_hooks_queue"

    def _is_running_from_plugin(self) -> bool:
        """True if the script lives under a plugin layout (cache dir).

        Looks for `.claude-plugin/plugin.json` two levels up from the script.
        """
        try:
            plugin_root = self._script_path.parent.parent
            return (plugin_root / ".claude-plugin" / "plugin.json").exists()
        except Exception:
            return False

    def _plugin_cache_data_dir(self) -> Path:
        """Resolve data dir when running from plugin cache layout.

        Plugin data lives at ~/.claude/plugins/data/<id>/, persistent across
        plugin updates. Falls back to a glob search if the canonical path
        is missing (e.g., older plugin manager versions used a different id
        normalisation).
        """
        home = Path.home()
        canonical = home / ".claude" / "plugins" / "data" / self.PLUGIN_ID
        if canonical.exists():
            return canonical
        data_root = home / ".claude" / "plugins" / "data"
        if data_root.exists():
            try:
                for child in data_root.iterdir():
                    if child.is_dir() and "audio-hooks" in child.name:
                        return child
            except OSError:
                pass
        return canonical  # canonical path; will be created on first write
```

- [ ] **Step 1.1.4: Verify path-resolution tests pass**

```bash
python -m pytest tests/test_user_preferences.py::TestPathResolution -v
```
Expected: all 7 tests PASS.

---

## Task 1.2 — Plugin overlay + load (without migration yet)

- [ ] **Step 1.2.1: Append load + plugin-overlay tests**

Append to `tests/test_user_preferences.py`:

```python
class TestPluginOverlay(unittest.TestCase):
    """CLAUDE_PLUGIN_OPTION_* env vars overlay onto loaded config."""

    def setUp(self):
        self._saved = {
            k: os.environ.pop(k, None)
            for k in (
                "CLAUDE_PLUGIN_DATA",
                "CLAUDE_PLUGIN_OPTION_AUDIO_THEME",
                "CLAUDE_PLUGIN_OPTION_WEBHOOK_URL",
                "CLAUDE_PLUGIN_OPTION_TTS_ENABLED",
            )
        }

    def tearDown(self):
        for k, v in self._saved.items():
            if v is not None:
                os.environ[k] = v
            else:
                os.environ.pop(k, None)

    def test_plugin_option_overlays_audio_theme(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["CLAUDE_PLUGIN_DATA"] = td
            os.environ["CLAUDE_PLUGIN_OPTION_AUDIO_THEME"] = "custom"
            (Path(td) / "user_preferences.json").write_text(
                json.dumps({"audio_theme": "default", "_version": "5.1.5"}),
                encoding="utf-8",
            )
            mod = _load_module()
            prefs = mod.UserPreferences(REPO)
            cfg = prefs.load()
            self.assertEqual(cfg["audio_theme"], "custom")  # overlay wins

    def test_plugin_option_dotted_keys(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["CLAUDE_PLUGIN_DATA"] = td
            os.environ["CLAUDE_PLUGIN_OPTION_WEBHOOK_URL"] = "https://example.com/hook"
            (Path(td) / "user_preferences.json").write_text(
                json.dumps({"_version": "5.1.5", "webhook_settings": {"url": ""}}),
                encoding="utf-8",
            )
            mod = _load_module()
            prefs = mod.UserPreferences(REPO)
            cfg = prefs.load()
            self.assertEqual(cfg["webhook_settings"]["url"], "https://example.com/hook")

    def test_load_auto_inits_from_template_when_missing(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["CLAUDE_PLUGIN_DATA"] = td
            mod = _load_module()
            prefs = mod.UserPreferences(REPO)
            cfg = prefs.load()
            # default_preferences.json has audio_theme: "default" (post-revert
            # baseline; will become subagent_stop=false after Phase 4 too)
            self.assertEqual(cfg["audio_theme"], "default")
            self.assertTrue((Path(td) / "user_preferences.json").exists())
```

- [ ] **Step 1.2.2: Verify new tests fail**

```bash
python -m pytest tests/test_user_preferences.py::TestPluginOverlay -v
```
Expected: 3 tests fail with `AttributeError: 'UserPreferences' object has no attribute 'load'`.

- [ ] **Step 1.2.3: Implement load + plugin overlay (no migration yet)**

Append to `hooks/user_preferences.py` inside the `UserPreferences` class:

```python
    # ------------------------------------------------------------------
    # Load
    # ------------------------------------------------------------------

    def _template_path(self) -> Path:
        return self.project_dir / "config" / "default_preferences.json"

    def _load_template(self) -> Dict[str, Any]:
        import json
        try:
            return json.loads(self._template_path().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def _auto_init(self) -> None:
        """Copy template into config_path if it doesn't exist yet."""
        if self.config_path.exists():
            return
        try:
            self.config_path.parent.mkdir(parents=True, exist_ok=True)
            template = self._template_path()
            if template.exists():
                import shutil
                shutil.copy2(str(template), str(self.config_path))
        except OSError:
            pass

    def load(self) -> Dict[str, Any]:
        """Read user_preferences.json, auto-init from template if missing,
        apply plugin-option env overlay. Migration is a no-op stub here;
        Task 1.3 implements the real merge logic."""
        import json
        self._auto_init()
        try:
            cfg = json.loads(self.config_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            cfg = {}
        cfg = self._apply_plugin_overlay(cfg)
        return cfg

    def _apply_plugin_overlay(self, cfg: Dict[str, Any]) -> Dict[str, Any]:
        """Overlay CLAUDE_PLUGIN_OPTION_* env vars onto config."""
        overlays = {
            "CLAUDE_PLUGIN_OPTION_AUDIO_THEME":   ("audio_theme", str),
            "CLAUDE_PLUGIN_OPTION_WEBHOOK_URL":   ("webhook_settings.url", str),
            "CLAUDE_PLUGIN_OPTION_WEBHOOK_FORMAT": ("webhook_settings.format", str),
            "CLAUDE_PLUGIN_OPTION_TTS_ENABLED":   ("tts_settings.enabled", lambda v: v.lower() in ("1", "true", "yes")),
        }
        for env_var, (dotted_key, coerce) in overlays.items():
            raw = os.environ.get(env_var, "").strip()
            if not raw:
                continue
            try:
                self._set_dotted_in(cfg, dotted_key, coerce(raw))
            except Exception:
                pass
        return cfg

    @staticmethod
    def _set_dotted_in(cfg: Dict[str, Any], dotted_key: str, value: Any) -> None:
        parts = dotted_key.split(".")
        node = cfg
        for p in parts[:-1]:
            if p not in node or not isinstance(node[p], dict):
                node[p] = {}
            node = node[p]
        node[parts[-1]] = value
```

Also add `import json` to the module top (if not already there). Update the imports block to:

```python
import json
import os
import platform
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
```

- [ ] **Step 1.2.4: Verify all tests pass**

```bash
python -m pytest tests/test_user_preferences.py -v
```
Expected: 10 tests PASS (7 path + 3 overlay).

---

## Task 1.3 — Migration (`_deep_merge_missing` + `_migrate`)

**Files:**
- Create: `tests/test_migration.py`
- Modify: `hooks/user_preferences.py` (append)

- [ ] **Step 1.3.1: Write failing tests for migration semantics**

Create `tests/test_migration.py`:

```python
"""Tests for UserPreferences migration semantics.

Each row in the migration table from the spec is pinned here:
- _version / version / $schema / _comment* always overwrite from template
- Other top-level keys: user wins if present, template adopted if missing
- Nested dicts: recurse with same rules
- Lists: atomic — user list wins entirely (no element merge)
- Type mismatch (scalar vs scalar): keep user
- Type mismatch (scalar vs container): reset to template default
- User has key template doesn't: keep user
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MODULE_PATH = REPO / "hooks" / "user_preferences.py"


def _load_module():
    sys.modules.pop("user_preferences", None)
    spec = importlib.util.spec_from_file_location("user_preferences", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestDeepMergeMissing(unittest.TestCase):
    """Pure-function tests of _deep_merge_missing — no IO."""

    def setUp(self):
        self.mod = _load_module()
        self.prefs = self.mod.UserPreferences(REPO)

    def test_empty_user_takes_full_template(self):
        template = {"audio_theme": "default", "x": {"y": 1}}
        merged, added = self.prefs._deep_merge_missing(template, {})
        self.assertEqual(merged, template)
        self.assertIn("audio_theme", added)
        self.assertIn("x.y", added)

    def test_existing_scalar_preserved_even_when_template_flips(self):
        template = {"subagent_stop": True}
        user = {"subagent_stop": False}
        merged, added = self.prefs._deep_merge_missing(template, user)
        self.assertEqual(merged["subagent_stop"], False)
        self.assertEqual(added, [])

    def test_new_key_added(self):
        template = {"a": 1, "b": 2}
        user = {"a": 99}
        merged, added = self.prefs._deep_merge_missing(template, user)
        self.assertEqual(merged, {"a": 99, "b": 2})
        self.assertEqual(added, ["b"])

    def test_user_extra_key_preserved(self):
        template = {"a": 1}
        user = {"a": 1, "future_key": "still_here"}
        merged, added = self.prefs._deep_merge_missing(template, user)
        self.assertEqual(merged["future_key"], "still_here")

    def test_nested_dict_recurses(self):
        template = {"webhook_settings": {"enabled": False, "format": "raw", "include_user_email": False}}
        user = {"webhook_settings": {"enabled": True, "format": "slack"}}
        merged, added = self.prefs._deep_merge_missing(template, user)
        self.assertEqual(merged["webhook_settings"]["enabled"], True)        # user wins
        self.assertEqual(merged["webhook_settings"]["format"], "slack")      # user wins
        self.assertEqual(merged["webhook_settings"]["include_user_email"], False)  # added
        self.assertIn("webhook_settings.include_user_email", added)

    def test_list_user_wins_entirely(self):
        template = {"hooks": ["stop", "notification", "permission_request"]}
        user = {"hooks": ["stop"]}  # user explicitly chose only one
        merged, added = self.prefs._deep_merge_missing(template, user)
        self.assertEqual(merged["hooks"], ["stop"])  # NOT merged with template

    def test_type_mismatch_scalar_vs_scalar_keeps_user(self):
        template = {"thresh": 80}
        user = {"thresh": "high"}  # weird, but recoverable
        merged, _added = self.prefs._deep_merge_missing(template, user)
        self.assertEqual(merged["thresh"], "high")

    def test_type_mismatch_scalar_vs_container_resets(self):
        """User's `enabled_hooks: true` (legacy) cannot be kept when template
        wants a dict — every downstream `.get(...)` would crash."""
        template = {"enabled_hooks": {"stop": True, "notification": True}}
        user = {"enabled_hooks": True}
        merged, _added = self.prefs._deep_merge_missing(template, user)
        self.assertEqual(merged["enabled_hooks"], {"stop": True, "notification": True})

    def test_comment_fields_always_overwritten(self):
        template = {"_comment": "v5.1.5 docs"}
        user = {"_comment": "v5.0.0 docs"}
        merged, _added = self.prefs._deep_merge_missing(template, user)
        self.assertEqual(merged["_comment"], "v5.1.5 docs")

    def test_metadata_fields_always_overwritten(self):
        template = {"_version": "5.1.5", "version": "5.1.5", "$schema": "./new.json"}
        user = {"_version": "5.1.3", "version": "5.1.3", "$schema": "./old.json"}
        merged, _added = self.prefs._deep_merge_missing(template, user)
        self.assertEqual(merged["_version"], "5.1.5")
        self.assertEqual(merged["version"], "5.1.5")
        self.assertEqual(merged["$schema"], "./new.json")


class TestMigrationFlow(unittest.TestCase):
    """Migration is triggered from load() when _version differs."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["CLAUDE_PLUGIN_DATA"] = self.tmp.name
        self.mod = _load_module()

    def tearDown(self):
        os.environ.pop("CLAUDE_PLUGIN_DATA", None)
        self.tmp.cleanup()

    def test_no_op_when_versions_match(self):
        prefs = self.mod.UserPreferences(REPO)
        template = prefs._load_template()
        user = dict(template)
        user["audio_theme"] = "custom"  # one customisation
        Path(self.tmp.name, "user_preferences.json").write_text(
            json.dumps(user), encoding="utf-8"
        )
        cfg = prefs.load()
        self.assertEqual(cfg["audio_theme"], "custom")
        # _version stayed same, file should be unchanged on disk
        on_disk = json.loads(Path(self.tmp.name, "user_preferences.json").read_text(encoding="utf-8"))
        self.assertEqual(on_disk["audio_theme"], "custom")

    def test_migration_bumps_version_and_writes_to_disk(self):
        prefs = self.mod.UserPreferences(REPO)
        old = {"_version": "5.1.3", "version": "5.1.3", "audio_theme": "custom"}
        Path(self.tmp.name, "user_preferences.json").write_text(
            json.dumps(old), encoding="utf-8"
        )
        cfg = prefs.load()
        # User's audio_theme preserved
        self.assertEqual(cfg["audio_theme"], "custom")
        # Version bumped to template's
        template_version = prefs._load_template().get("_version")
        self.assertEqual(cfg["_version"], template_version)
        # Persisted to disk
        on_disk = json.loads(Path(self.tmp.name, "user_preferences.json").read_text(encoding="utf-8"))
        self.assertEqual(on_disk["_version"], template_version)
        # New keys merged in (e.g., enabled_hooks block from template)
        self.assertIn("enabled_hooks", cfg)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 1.3.2: Verify migration tests fail**

```bash
python -m pytest tests/test_migration.py -v
```
Expected: 12 tests fail (`_deep_merge_missing` and `_migrate` not defined).

- [ ] **Step 1.3.3: Implement `_deep_merge_missing` + migration**

Append to `UserPreferences` class:

```python
    # ------------------------------------------------------------------
    # Migration
    # ------------------------------------------------------------------

    METADATA_KEYS = ("_version", "version", "$schema")
    COMMENT_PREFIX = "_"

    def _deep_merge_missing(
        self,
        template: Dict[str, Any],
        user: Dict[str, Any],
        _path: str = "",
    ) -> Tuple[Dict[str, Any], List[str]]:
        """Return (merged_dict, list_of_added_dotted_paths).

        Rules (see spec):
          - METADATA_KEYS + comment fields (_*): always take template
          - dict in template, dict in user → recurse
          - dict in template, scalar in user → reset to template (unrecoverable)
          - any other case where user has a value: keep user value
          - key in template but not user: adopt template value
        """
        merged: Dict[str, Any] = dict(user)
        added: List[str] = []
        for k, t_val in template.items():
            full_path = f"{_path}.{k}" if _path else k
            # Metadata + comment fields: always overwrite
            if k in self.METADATA_KEYS or k.startswith(self.COMMENT_PREFIX):
                if k not in user:
                    added.append(full_path)
                merged[k] = t_val
                continue
            # New key: adopt template
            if k not in user:
                merged[k] = t_val
                added.append(full_path)
                continue
            u_val = user[k]
            # dict in template, scalar/list in user → reset
            if isinstance(t_val, dict) and not isinstance(u_val, dict):
                merged[k] = t_val
                continue
            # Both dicts: recurse
            if isinstance(t_val, dict) and isinstance(u_val, dict):
                sub, sub_added = self._deep_merge_missing(t_val, u_val, full_path)
                merged[k] = sub
                added.extend(sub_added)
                continue
            # Otherwise (scalar-vs-scalar, list-vs-anything, etc.): keep user
            merged[k] = u_val
        return merged, added

    def _migrate_if_needed(self, cfg: Dict[str, Any], template: Dict[str, Any]) -> Tuple[Dict[str, Any], bool, List[str]]:
        """Return (cfg_after_migration, did_migrate, added_keys)."""
        user_v = cfg.get("_version", "0.0.0")
        template_v = template.get("_version", "0.0.0")
        if user_v == template_v:
            return cfg, False, []
        merged, added = self._deep_merge_missing(template, cfg)
        merged["_version"] = template_v
        merged["version"] = template_v
        return merged, True, added
```

Now wire `_migrate_if_needed` into `load()`:

```python
    def load(self) -> Dict[str, Any]:
        """Read user_preferences.json, auto-init from template if missing,
        auto-migrate if older _version detected, apply plugin-option env overlay."""
        self._auto_init()
        try:
            cfg = json.loads(self.config_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            cfg = {}
        template = self._load_template()
        cfg, did_migrate, added_keys = self._migrate_if_needed(cfg, template)
        if did_migrate:
            # Persist via direct write — save() with backup is implemented in Task 1.4.
            # For now, atomic write only (no backup) — bootstrap-friendly so Phase 1
            # tests that don't exercise the backup path still pass.
            self._atomic_write_json(self.config_path, cfg)
        cfg = self._apply_plugin_overlay(cfg)
        return cfg

    def _atomic_write_json(self, target: Path, cfg: Dict[str, Any]) -> None:
        """Stub atomic write — Task 1.4 expands this with locks + backups."""
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_suffix(target.suffix + f".tmp.{os.getpid()}")
        tmp.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, target)
```

- [ ] **Step 1.3.4: Verify migration tests pass**

```bash
python -m pytest tests/test_migration.py tests/test_user_preferences.py -v
```
Expected: 22 tests PASS.

---

## Task 1.4 — save() + backup mechanics + lock

**Files:**
- Create: `tests/test_backups.py`
- Modify: `hooks/user_preferences.py` (append save + backup methods)

- [ ] **Step 1.4.1: Write failing tests for save + backup**

Create `tests/test_backups.py`:

```python
"""Tests for save() and backup mechanics (sibling .bak + external rotation)."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Optional

REPO = Path(__file__).resolve().parent.parent
MODULE_PATH = REPO / "hooks" / "user_preferences.py"


def _load_module():
    sys.modules.pop("user_preferences", None)
    spec = importlib.util.spec_from_file_location("user_preferences", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestSaveSibling(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fake_home = tempfile.TemporaryDirectory()
        os.environ["CLAUDE_PLUGIN_DATA"] = self.tmp.name
        self.mod = _load_module()
        self._original_home = self.mod.Path.home
        self.mod.Path.home = staticmethod(lambda: self.mod.Path(self.fake_home.name))

    def tearDown(self):
        self.mod.Path.home = self._original_home
        os.environ.pop("CLAUDE_PLUGIN_DATA", None)
        self.tmp.cleanup()
        self.fake_home.cleanup()

    def test_save_writes_atomically(self):
        prefs = self.mod.UserPreferences(REPO)
        prefs.save({"_version": "5.1.5", "audio_theme": "custom"})
        on_disk = json.loads(Path(self.tmp.name, "user_preferences.json").read_text(encoding="utf-8"))
        self.assertEqual(on_disk["audio_theme"], "custom")

    def test_save_creates_sibling_bak_after_second_save(self):
        prefs = self.mod.UserPreferences(REPO)
        prefs.save({"_version": "5.1.5", "audio_theme": "default"})
        prefs.save({"_version": "5.1.5", "audio_theme": "custom"})
        bak = Path(self.tmp.name, "user_preferences.json.bak")
        self.assertTrue(bak.exists(), "sibling .bak not created on second save")
        bak_content = json.loads(bak.read_text(encoding="utf-8"))
        self.assertEqual(bak_content["audio_theme"], "default")  # prior state

    def test_first_save_no_sibling_bak(self):
        """First save has no prior content — no backup written."""
        prefs = self.mod.UserPreferences(REPO)
        prefs.save({"_version": "5.1.5"})
        bak = Path(self.tmp.name, "user_preferences.json.bak")
        self.assertFalse(bak.exists())


class TestExternalBackups(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fake_home = tempfile.TemporaryDirectory()
        os.environ["CLAUDE_PLUGIN_DATA"] = self.tmp.name
        self.mod = _load_module()
        self._original_home = self.mod.Path.home
        self.mod.Path.home = staticmethod(lambda: self.mod.Path(self.fake_home.name))

    def tearDown(self):
        self.mod.Path.home = self._original_home
        os.environ.pop("CLAUDE_PLUGIN_DATA", None)
        self.tmp.cleanup()
        self.fake_home.cleanup()

    def _external_dir(self) -> Path:
        return Path(self.fake_home.name) / ".claude-audio-hooks-backups" / "audio-hooks-chanmeng-audio-hooks"

    def test_external_backup_created_on_second_save(self):
        prefs = self.mod.UserPreferences(REPO)
        prefs.save({"_version": "5.1.5", "audio_theme": "default"})
        prefs.save({"_version": "5.1.5", "audio_theme": "custom"})
        files = list(self._external_dir().glob("*.json"))
        self.assertEqual(len(files), 1, f"Expected 1 external backup, got {[f.name for f in files]}")

    def test_dedup_skips_byte_identical_save(self):
        prefs = self.mod.UserPreferences(REPO)
        cfg = {"_version": "5.1.5", "audio_theme": "default"}
        prefs.save(cfg)
        prefs.save(cfg)  # identical
        prefs.save(cfg)  # identical again
        files = list(self._external_dir().glob("*.json"))
        self.assertEqual(len(files), 1, "byte-identical saves should not create new backups")

    def test_rotation_at_keep_limit(self):
        """Generate KEEP+5 saves with distinct content, expect KEEP files retained."""
        prefs = self.mod.UserPreferences(REPO)
        for i in range(self.mod.UserPreferences.EXTERNAL_BACKUP_KEEP + 5):
            prefs.save({"_version": "5.1.5", "iteration": i})
        files = list(self._external_dir().glob("*.json"))
        self.assertLessEqual(
            len(files),
            self.mod.UserPreferences.EXTERNAL_BACKUP_KEEP,
            f"Rotation failed: kept {len(files)} files",
        )


class TestBackupListAndRestore(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fake_home = tempfile.TemporaryDirectory()
        os.environ["CLAUDE_PLUGIN_DATA"] = self.tmp.name
        self.mod = _load_module()
        self._original_home = self.mod.Path.home
        self.mod.Path.home = staticmethod(lambda: self.mod.Path(self.fake_home.name))

    def tearDown(self):
        self.mod.Path.home = self._original_home
        os.environ.pop("CLAUDE_PLUGIN_DATA", None)
        self.tmp.cleanup()
        self.fake_home.cleanup()

    def test_list_backups_returns_newest_first(self):
        prefs = self.mod.UserPreferences(REPO)
        prefs.save({"_version": "5.1.5", "audio_theme": "default"})
        prefs.save({"_version": "5.1.5", "audio_theme": "custom"})
        prefs.save({"_version": "5.1.5", "audio_theme": "voice"})
        entries = prefs.list_backups()
        self.assertGreater(len(entries), 0)
        # First should be most recent by mtime
        for i in range(len(entries) - 1):
            self.assertGreaterEqual(entries[i]["mtime_iso"], entries[i + 1]["mtime_iso"])

    def test_restore_from_latest_round_trips(self):
        prefs = self.mod.UserPreferences(REPO)
        prefs.save({"_version": "5.1.5", "audio_theme": "default"})
        prefs.save({"_version": "5.1.5", "audio_theme": "custom"})
        # Now restore latest (which is the saved-content of the prior save = "default")
        restored = prefs.restore_from("latest-external")
        self.assertEqual(restored["audio_theme"], "default")

    def test_filename_id_round_trip(self):
        prefs = self.mod.UserPreferences(REPO)
        ids = [
            "2026-05-01T07:42:13.041Z",
            "2026-12-31T23:59:59.999Z",
            "2026-01-01T00:00:00.000Z",
        ]
        for original in ids:
            fname = prefs._id_to_filename(original)
            recovered = prefs._filename_to_id(fname)
            self.assertEqual(recovered, original, f"round-trip failed for {original}")
            self.assertNotIn(":", fname, "filename must not contain : (Windows-incompatible)")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 1.4.2: Verify backup tests fail**

```bash
python -m pytest tests/test_backups.py -v
```
Expected: ~10 tests fail with `AttributeError: 'UserPreferences' object has no attribute 'save'` etc.

- [ ] **Step 1.4.3: Implement save + backup methods**

Append to `UserPreferences` class:

```python
    # ------------------------------------------------------------------
    # Save + backup
    # ------------------------------------------------------------------

    @property
    def external_backup_dir(self) -> Path:
        return Path.home() / self.EXTERNAL_BACKUP_DIRNAME / self.PLUGIN_ID

    @property
    def sibling_backup_path(self) -> Path:
        return self.config_path.with_suffix(".json.bak")

    @staticmethod
    def _id_to_filename(backup_id: str) -> str:
        return backup_id.replace(":", "-") + ".json"

    @staticmethod
    def _filename_to_id(filename: str) -> str:
        # 2026-05-01T07-42-13.041Z.json -> 2026-05-01T07:42:13.041Z
        stem = filename
        if stem.endswith(".json"):
            stem = stem[:-5]
        # Restore : at positions 13 and 16
        if len(stem) >= 17 and stem[13] == "-" and stem[16] == "-":
            return stem[:13] + ":" + stem[14:16] + ":" + stem[17:]
        return stem

    def _current_iso_id(self) -> str:
        import time
        t = time.time()
        ms = int((t - int(t)) * 1000)
        return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + f".{ms:03d}Z"

    def _snapshot_backup(self) -> Optional[str]:
        """Snapshot current config file content to sibling .bak + external dir.

        Returns the ID of the newly created external backup, or None if no
        backup was needed (first save / dedup hit).
        """
        if not self.config_path.exists():
            return None
        try:
            current_bytes = self.config_path.read_bytes()
        except OSError:
            return None

        # Sibling: overwrite
        try:
            self.sibling_backup_path.write_bytes(current_bytes)
        except OSError:
            pass

        # External: dedup
        ext_dir = self.external_backup_dir
        try:
            ext_dir.mkdir(parents=True, exist_ok=True)
        except OSError:
            return None

        existing = sorted(
            ext_dir.glob("*.json"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if existing:
            try:
                if existing[0].read_bytes() == current_bytes:
                    return None  # dedup
            except OSError:
                pass

        backup_id = self._current_iso_id()
        target = ext_dir / self._id_to_filename(backup_id)
        try:
            target.write_bytes(current_bytes)
        except OSError:
            return None

        # Rotation
        self.prune_backups()
        return backup_id

    def prune_backups(self, keep: int = None) -> int:
        """Trim external dir to KEEP most recent. Returns count removed."""
        if keep is None:
            keep = self.EXTERNAL_BACKUP_KEEP
        ext_dir = self.external_backup_dir
        if not ext_dir.exists():
            return 0
        files = sorted(
            ext_dir.glob("*.json"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        removed = 0
        for f in files[keep:]:
            try:
                f.unlink()
                removed += 1
            except OSError:
                pass
        return removed

    def save(self, cfg: Dict[str, Any]) -> Optional[str]:
        """Atomically write cfg to disk, snapshotting prior content first.

        Returns the ID of the external backup created (None on first save
        or when content is byte-identical to the latest backup).
        """
        with self._acquire_lock():
            backup_id = self._snapshot_backup()
            self._atomic_write_json(self.config_path, cfg)
            return backup_id

    def list_backups(self) -> List[Dict[str, Any]]:
        """Return list of backup entries, newest first."""
        import datetime
        entries: List[Dict[str, Any]] = []
        # External
        ext_dir = self.external_backup_dir
        if ext_dir.exists():
            for f in ext_dir.glob("*.json"):
                try:
                    stat = f.stat()
                except OSError:
                    continue
                backup_id = self._filename_to_id(f.name)
                try:
                    body = json.loads(f.read_text(encoding="utf-8"))
                    from_version = body.get("_version", "unknown")
                except (OSError, ValueError):
                    from_version = "unknown"
                entries.append({
                    "id": backup_id,
                    "location": "external",
                    "path": str(f),
                    "size_bytes": stat.st_size,
                    "from_version": from_version,
                    "mtime_iso": datetime.datetime.utcfromtimestamp(
                        stat.st_mtime
                    ).strftime("%Y-%m-%dT%H:%M:%SZ"),
                })
        # Sibling
        sib = self.sibling_backup_path
        if sib.exists():
            try:
                stat = sib.stat()
                body = json.loads(sib.read_text(encoding="utf-8"))
                from_version = body.get("_version", "unknown")
                entries.append({
                    "id": "latest-sibling",
                    "location": "sibling",
                    "path": str(sib),
                    "size_bytes": stat.st_size,
                    "from_version": from_version,
                    "mtime_iso": datetime.datetime.utcfromtimestamp(
                        stat.st_mtime
                    ).strftime("%Y-%m-%dT%H:%M:%SZ"),
                })
            except OSError:
                pass
        # Sort newest first by mtime_iso
        entries.sort(key=lambda e: e["mtime_iso"], reverse=True)
        return entries

    def restore_from(self, backup_id: str) -> Dict[str, Any]:
        """Restore config from a backup. Magic strings: latest, latest-sibling,
        latest-external. Or an exact ISO timestamp matching an external backup.

        Returns the restored config dict. The current state is itself
        snapshotted via save() before being overwritten.
        """
        entries = self.list_backups()
        target_path: Optional[Path] = None
        if backup_id == "latest":
            if entries:
                target_path = Path(entries[0]["path"])
        elif backup_id == "latest-sibling":
            for e in entries:
                if e["location"] == "sibling":
                    target_path = Path(e["path"])
                    break
        elif backup_id == "latest-external":
            for e in entries:
                if e["location"] == "external":
                    target_path = Path(e["path"])
                    break
        else:
            # Exact ID match (external only)
            for e in entries:
                if e["id"] == backup_id and e["location"] == "external":
                    target_path = Path(e["path"])
                    break
        if target_path is None or not target_path.exists():
            raise FileNotFoundError(f"backup not found: {backup_id}")
        try:
            cfg = json.loads(target_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            raise ValueError(f"backup unreadable: {e}") from e
        self.save(cfg)  # itself triggers a backup of pre-restore state
        return cfg

    # ------------------------------------------------------------------
    # File lock (cross-platform)
    # ------------------------------------------------------------------

    def _lock_path(self) -> Path:
        return self.data_dir / ".user_prefs.lock"

    class _LockTimeout(Exception):
        pass

    def _acquire_lock(self):
        """Context manager: exclusive lock on .user_prefs.lock file."""
        return _UserPrefsLock(self._lock_path(), self.LOCK_TIMEOUT_SECONDS)
```

Then add the `_UserPrefsLock` helper class at module top level (BELOW the `UserPreferences` class, since it's a private helper):

```python
class _UserPrefsLock:
    """Cross-platform exclusive file lock context manager."""

    def __init__(self, lock_path: Path, timeout_seconds: float):
        self.lock_path = lock_path
        self.timeout = timeout_seconds
        self._fh = None

    def __enter__(self):
        import time
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        self._fh = open(self.lock_path, "a+b")
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                self._try_lock()
                return self
            except OSError:
                if time.monotonic() >= deadline:
                    self._fh.close()
                    raise UserPreferences._LockTimeout(
                        f"could not acquire {self.lock_path} within {self.timeout}s"
                    )
                time.sleep(0.05)

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self._fh is not None:
            try:
                self._unlock()
            finally:
                self._fh.close()
                self._fh = None
        return False

    def _try_lock(self):
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(self._fh.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(self._fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    def _unlock(self):
        if os.name == "nt":
            import msvcrt
            try:
                self._fh.seek(0)
                msvcrt.locking(self._fh.fileno(), msvcrt.LK_UNLCK, 1)
            except OSError:
                pass
        else:
            import fcntl
            try:
                fcntl.flock(self._fh.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
```

- [ ] **Step 1.4.4: Verify backup tests pass**

```bash
python -m pytest tests/test_backups.py -v
```
Expected: 9 tests PASS (3 sibling + 3 external + 3 list/restore).

- [ ] **Step 1.4.5: Run full Phase 1 test suite**

```bash
python -m pytest tests/test_user_preferences.py tests/test_migration.py tests/test_backups.py -v
```
Expected: 31 tests PASS.

---

## Task 1.5 — get_prefs() singleton + diff_from_default + get_dotted/set_dotted

- [ ] **Step 1.5.1: Append singleton + accessor tests**

Append to `tests/test_user_preferences.py`:

```python
class TestSingletonAndAccessors(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["CLAUDE_PLUGIN_DATA"] = self.tmp.name
        self.mod = _load_module()
        # Reset singleton between tests
        self.mod._reset_prefs()

    def tearDown(self):
        os.environ.pop("CLAUDE_PLUGIN_DATA", None)
        self.tmp.cleanup()

    def test_get_prefs_returns_singleton(self):
        a = self.mod.get_prefs(REPO)
        b = self.mod.get_prefs(REPO)
        self.assertIs(a, b)

    def test_reset_prefs_clears_singleton(self):
        a = self.mod.get_prefs(REPO)
        self.mod._reset_prefs()
        b = self.mod.get_prefs(REPO)
        self.assertIsNot(a, b)

    def test_get_dotted_walks_nested_dict(self):
        prefs = self.mod.UserPreferences(REPO)
        prefs.save({
            "_version": "5.1.5",
            "audio_theme": "custom",
            "webhook_settings": {"url": "https://x.example"},
        })
        self.assertEqual(prefs.get_dotted("audio_theme"), "custom")
        self.assertEqual(prefs.get_dotted("webhook_settings.url"), "https://x.example")
        self.assertIsNone(prefs.get_dotted("nonexistent.key"))

    def test_set_dotted_persists_via_save(self):
        prefs = self.mod.UserPreferences(REPO)
        prefs.save({"_version": "5.1.5", "audio_theme": "default"})
        prefs.set_dotted("audio_theme", "custom")
        # Round-trip via load
        cfg = prefs.load()
        self.assertEqual(cfg["audio_theme"], "custom")

    def test_diff_from_default_excludes_template_matching_values(self):
        prefs = self.mod.UserPreferences(REPO)
        template = prefs._load_template()
        # Save the template verbatim
        prefs.save(template)
        diff = prefs.diff_from_default()
        # Should be empty or only contain comment/version fields (excluded from diff)
        for k in diff:
            self.assertFalse(k.startswith("_"), f"diff includes comment field {k}")
            self.assertNotIn(k, ("_version", "version", "$schema"))
```

- [ ] **Step 1.5.2: Implement singleton + accessors**

At the bottom of `hooks/user_preferences.py` (outside the class):

```python
# ----------------------------------------------------------------------
# Module-level lazy singleton
# ----------------------------------------------------------------------

_prefs_instance: Optional[UserPreferences] = None


def get_prefs(project_dir: Optional[Path] = None, *, script_path: Optional[Path] = None) -> UserPreferences:
    """Return the process-wide UserPreferences singleton. Lazy-initialised."""
    global _prefs_instance
    if _prefs_instance is None:
        if project_dir is None:
            # Walk up from this file to find a project root with config/default_preferences.json
            here = Path(__file__).resolve()
            for ancestor in [here.parent] + list(here.parents):
                if (ancestor / "config" / "default_preferences.json").exists():
                    project_dir = ancestor
                    break
            if project_dir is None:
                raise RuntimeError("Cannot locate project_dir for UserPreferences")
        _prefs_instance = UserPreferences(project_dir, script_path=script_path)
    return _prefs_instance


def _reset_prefs() -> None:
    """Test-only: clear the singleton so the next get_prefs() reinitialises."""
    global _prefs_instance
    _prefs_instance = None
```

Inside `UserPreferences` class, add `get_dotted` / `set_dotted` / `diff_from_default`:

```python
    # ------------------------------------------------------------------
    # Convenience accessors
    # ------------------------------------------------------------------

    def get_dotted(self, dotted_key: str) -> Any:
        cfg = self.load()
        node: Any = cfg
        for part in dotted_key.split("."):
            if not isinstance(node, dict) or part not in node:
                return None
            node = node[part]
        return node

    def set_dotted(self, dotted_key: str, value: Any) -> None:
        cfg = self.load()
        self._set_dotted_in(cfg, dotted_key, value)
        self.save(cfg)

    def diff_from_default(self) -> Dict[str, Any]:
        """Return a flat dotted-key dict of values where user differs from
        bundled default_preferences.json. Excludes metadata + comment fields.
        """
        user = self.load()
        template = self._load_template()
        out: Dict[str, Any] = {}
        self._collect_diff(template, user, "", out)
        return out

    def _collect_diff(
        self,
        template: Dict[str, Any],
        user: Dict[str, Any],
        prefix: str,
        out: Dict[str, Any],
    ) -> None:
        for k, u_val in user.items():
            if k in self.METADATA_KEYS or k.startswith(self.COMMENT_PREFIX):
                continue
            full = f"{prefix}.{k}" if prefix else k
            if k not in template:
                out[full] = u_val
                continue
            t_val = template[k]
            if isinstance(t_val, dict) and isinstance(u_val, dict):
                self._collect_diff(t_val, u_val, full, out)
            elif u_val != t_val:
                out[full] = u_val
```

- [ ] **Step 1.5.3: Verify singleton tests pass + full Phase 1 suite**

```bash
python -m pytest tests/test_user_preferences.py tests/test_migration.py tests/test_backups.py -v
```
Expected: 36 tests PASS (31 prior + 5 new).

---

## Task 1.6 — Phase 1 commit

- [ ] **Step 1.6.1: Run the entire test suite**

```bash
python -m pytest tests/ -q
```
Expected: 76 tests pass (40 prior + 36 new).

- [ ] **Step 1.6.2: Sanity-check the new module compiles and has no import-time side effects**

```bash
python -c "import sys; sys.path.insert(0, 'hooks'); import user_preferences; print('OK', user_preferences.UserPreferences.__name__)"
```
Expected: `OK UserPreferences`.

- [ ] **Step 1.6.3: Commit Phase 1**

```bash
git add hooks/user_preferences.py tests/test_user_preferences.py tests/test_migration.py tests/test_backups.py
git commit -m "$(cat <<'EOF'
feat(prefs): add UserPreferences class as single source of truth

New hooks/user_preferences.py owns path resolution, load (auto-migrate),
save (auto-backup), backup management, and diff-from-default reporting.
This commit only ADDS the class + tests — no call-site migration yet, so
existing hook_runner.py and bin/audio-hooks.py continue to work via
their current helpers.

The class follows the spec at docs/specs/2026-05-01-painless-upgrades-design.md:
- Lazy get_prefs() singleton (no import-time side effects)
- 6-level path resolution chain (env vars -> plugin layout -> shared dir
  -> cursor-native dir -> legacy temp), pinning the 5.1.4 anti-stranding
  shared-dir branch with a regression test
- Migration on load with deep-merge-missing semantics; lists are atomic;
  scalar-vs-container mismatch resets to template default
- Atomic write via os.replace + cross-platform file lock
  (fcntl.flock POSIX, msvcrt.locking Windows) on .user_prefs.lock
- Dual-location backups: sibling .bak (last good) + external timestamped
  history at ~/.claude-audio-hooks-backups/<plugin_id>/<ts>.json
  (rotation: keep 20, dedup byte-identical content)
- ISO-8601 timestamp IDs with millisecond suffix; round-trippable
  filename<->id conversion for Windows compatibility (replaces : with -)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```
Expected: commit succeeds. Verify with `git log --oneline -1`.

---

# Phase 2 — migrate call sites

**Files modified:**
- `hooks/hook_runner.py` — delete duplicated helpers, route through `get_prefs()`
- `bin/audio-hooks.py` — delete duplicated helpers, route through `get_prefs()`
- `tests/test_cursor_bridge.py` — adapt tests that referenced internal helpers

**Phase commit message:**
```
refactor(prefs): migrate hook_runner + audio-hooks CLI onto UserPreferences

Removes the duplicated _resolve_plugin_data_dir / _is_running_from_plugin /
_auto_init_user_prefs / _apply_plugin_option_overlay helpers from both
hooks/hook_runner.py and bin/audio-hooks.py — they now live exclusively in
hooks/user_preferences.py. Module-level globals (CONFIG_FILE, QUEUE_DIR)
are removed; consumers acquire paths via get_prefs() instead.

This eliminates the dual-implementation bug class that caused 5.1.4: a fix
applied to one copy never propagated to the other. The CLI (bin/audio-hooks.py)
and the runtime (hooks/hook_runner.py) now agree on path resolution by
construction.

No user-visible behavior change. All existing tests still pass; the cursor
bridge regression test (5.1.4 anti-stranding) remains green.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 2.1 — Adapt hook_runner.py

- [ ] **Step 2.1.1: Locate the helpers to delete**

Run:

```bash
grep -n "^def _resolve_plugin_data_dir\|^def _resolve_data_dir\|^def _is_running_from_plugin\|^def _auto_init_user_prefs\|^def _apply_plugin_option_overlay\|^def _resolve_config_file\|^def _resolve_queue_dir\|^def get_log_dir\|^def detect_invoker\|^def _get_invoker\|^CONFIG_FILE = \|^QUEUE_DIR = " hooks/hook_runner.py
```

Expected output (line numbers will vary, content should match):
```
hooks/hook_runner.py:NNN:def get_log_dir() -> Path:
hooks/hook_runner.py:NNN:def _resolve_data_dir() -> Path:
hooks/hook_runner.py:NNN:def detect_invoker() -> str:
hooks/hook_runner.py:NNN:def _get_invoker() -> str:
hooks/hook_runner.py:NNN:def _is_running_from_plugin() -> bool:
hooks/hook_runner.py:NNN:def _resolve_plugin_data_dir() -> Path:
hooks/hook_runner.py:NNN:def _auto_init_user_prefs(target: Path) -> None:
hooks/hook_runner.py:NNN:def _resolve_config_file() -> Path:
hooks/hook_runner.py:NNN:CONFIG_FILE = _resolve_config_file()
hooks/hook_runner.py:NNN:def _resolve_queue_dir() -> Path:
hooks/hook_runner.py:NNN:QUEUE_DIR = _resolve_queue_dir()
```

- [ ] **Step 2.1.2: Add UserPreferences import + module-level access helpers**

At the top of `hooks/hook_runner.py`, near the existing imports, add:

```python
from user_preferences import UserPreferences, get_prefs  # type: ignore
```

Note: `hooks/` is on `sys.path` because `runner/run.py` inserts it. For direct invocation paths (like the existing `from typing import ...`), the imports already resolve at the same level.

Replace the module-level globals with property-style accessors at the same location they used to be:

```python
# Module-level convenience: all path resolution flows through UserPreferences.
# get_prefs() is lazy-initialised on first call.

def _prefs() -> UserPreferences:
    return get_prefs(PROJECT_DIR)


def get_log_dir() -> Path:
    """Resolve the log directory, creating it if necessary.

    Backwards-compatible wrapper around UserPreferences.log_dir.
    """
    log_dir = _prefs().log_dir
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    return log_dir
```

Delete the now-superseded helpers from `hook_runner.py`:
- `_resolve_data_dir` (entire function)
- `_is_running_from_plugin` (entire function)
- `_resolve_plugin_data_dir` (entire function)
- `_auto_init_user_prefs` (entire function)
- `_resolve_config_file` (entire function)
- `_resolve_queue_dir` (entire function)
- `CONFIG_FILE = _resolve_config_file()` line
- `QUEUE_DIR = _resolve_queue_dir()` line

- [ ] **Step 2.1.3: Replace call sites of deleted helpers**

For every reference to `CONFIG_FILE`, replace with `_prefs().config_path`.
For every reference to `QUEUE_DIR`, replace with `_prefs().queue_dir`.

Run:

```bash
grep -n "CONFIG_FILE\|QUEUE_DIR" hooks/hook_runner.py
```

Expected: zero matches (or only docstrings / comments).

For `load_config()` (the existing function that reads + applies overlay), replace its body:

```python
def load_config() -> Dict[str, Any]:
    """Read user_preferences.json with auto-migration and plugin-option overlay."""
    return _prefs().load()
```

Delete the existing `_apply_plugin_option_overlay` function in `hook_runner.py` (the class handles overlay).

- [ ] **Step 2.1.4: Verify hook_runner imports without errors**

```bash
python -c "import sys; sys.path.insert(0, 'hooks'); import hook_runner; print('OK', hook_runner.HOOK_RUNNER_VERSION)"
```
Expected: `OK 5.1.4` (still 5.1.4; bumps to 5.1.5 in Phase 5).

- [ ] **Step 2.1.5: Run all tests**

```bash
python -m pytest tests/ -v
```
Expected: 76 tests PASS. If any test fails, the most likely cause is a missed call site of `CONFIG_FILE` / `QUEUE_DIR` / a deleted helper. Fix and re-run.

---

## Task 2.2 — Adapt bin/audio-hooks.py

- [ ] **Step 2.2.1: Locate the helpers to delete**

```bash
grep -n "^def _config_path\|^def _resolve_plugin_data_dir\|^def _is_running_from_plugin\|^def _auto_init_user_prefs\|^def _apply_plugin_option_overlay\|^def _load_config_raw\|^def _save_config_raw" bin/audio-hooks.py
```

- [ ] **Step 2.2.2: Add import + replace _config_path / _load_config_raw / _save_config_raw**

At the top of `bin/audio-hooks.py`, add:

```python
# Import UserPreferences from hooks/
if PROJECT_ROOT is not None:
    hooks_dir = PROJECT_ROOT / "hooks"
    if str(hooks_dir) not in sys.path:
        sys.path.insert(0, str(hooks_dir))
try:
    from user_preferences import UserPreferences, get_prefs  # type: ignore
except ImportError:
    UserPreferences = None  # type: ignore
    def get_prefs(*_a, **_k):  # type: ignore
        raise RuntimeError("user_preferences module unavailable; reinstall the project")
```

Replace `_config_path` with a thin wrapper:

```python
def _config_path() -> Path:
    """Backwards-compatible wrapper. New code should use _prefs().config_path."""
    return _prefs().config_path


def _prefs() -> UserPreferences:
    return get_prefs(PROJECT_ROOT)
```

Replace `_load_config_raw` body:

```python
def _load_config_raw() -> Dict[str, Any]:
    """Load user_preferences.json with auto-migration."""
    if PROJECT_ROOT is None:
        return {}
    try:
        return _prefs().load()
    except Exception:
        return {}
```

Replace `_save_config_raw` body:

```python
def _save_config_raw(cfg: Dict[str, Any]) -> Tuple[bool, str]:
    """Save user_preferences.json with auto-backup."""
    if PROJECT_ROOT is None:
        return False, "PROJECT_ROOT not detected"
    try:
        _prefs().save(cfg)
        return True, ""
    except Exception as e:
        return False, str(e)
```

Delete the now-superseded helpers from `bin/audio-hooks.py`:
- `_resolve_plugin_data_dir` (and its module-level call sites)
- `_is_running_from_plugin`
- `_auto_init_user_prefs`
- `_apply_plugin_option_overlay`

- [ ] **Step 2.2.3: Verify bin/audio-hooks.py works**

```bash
python bin/audio-hooks.py version
python bin/audio-hooks.py status
```

Expected: both emit valid JSON with `"ok":true`. The status output should match what it printed before this commit (theme, enabled hooks, editor_targets).

- [ ] **Step 2.2.4: Run all tests**

```bash
python -m pytest tests/ -v
```
Expected: 76 tests pass.

---

## Task 2.3 — Update test_cursor_bridge.py if needed

Tests in `test_cursor_bridge.py` that use internal helpers now-removed from hook_runner may need adjustment.

- [ ] **Step 2.3.1: Identify references**

```bash
grep -n "hook_runner\._resolve_data_dir\|hook_runner\.detect_invoker\|hook_runner\._is_running_from_plugin\|hook_runner\._resolve_plugin_data_dir" tests/test_cursor_bridge.py
```

- [ ] **Step 2.3.2: Adapt tests**

For each match: if the symbol still exists in `hook_runner.py` (e.g., `detect_invoker` is kept as a public function), no change needed. If a test references `hook_runner._resolve_data_dir`, redirect it to `user_preferences.UserPreferences._resolve_data_dir` (or use a UserPreferences instance fixture instead).

Note: the existing `TestResolveConfigFileSharedFallback` test (added in commit `f743187`) depends on `hook_runner._resolve_config_file`. Since we removed that function, the test must be either:
- Adapted to use `UserPreferences.config_path`
- Or moved to `test_user_preferences.py`

Since `test_user_preferences.py` already covers the equivalent path resolution (via `TestPathResolution.test_shared_dir_used_when_user_prefs_exists_there`), **delete `TestResolveConfigFileSharedFallback` from `test_cursor_bridge.py`** — coverage is preserved by the new tests.

- [ ] **Step 2.3.3: Run cursor-bridge tests**

```bash
python -m pytest tests/test_cursor_bridge.py -v
```
Expected: all remaining cursor-bridge tests pass.

- [ ] **Step 2.3.4: Run full suite**

```bash
python -m pytest tests/ -v
```
Expected: 76 tests pass (or 74 if the 2 removed tests aren't replaced; test_user_preferences.py covers the same scenarios).

---

## Task 2.4 — Phase 2 commit

- [ ] **Step 2.4.1: Verify no orphaned references**

```bash
grep -rn "_resolve_plugin_data_dir\|_resolve_data_dir\|_is_running_from_plugin\|_auto_init_user_prefs\|_apply_plugin_option_overlay" hooks/hook_runner.py bin/audio-hooks.py
```
Expected: zero matches in either file.

- [ ] **Step 2.4.2: End-to-end smoke test**

```bash
python bin/audio-hooks.py status
python bin/audio-hooks.py theme set custom
python bin/audio-hooks.py status
python bin/audio-hooks.py theme set default
```
Expected: each emits valid JSON; theme persists across calls.

- [ ] **Step 2.4.3: Commit Phase 2**

```bash
git add hooks/hook_runner.py bin/audio-hooks.py tests/test_cursor_bridge.py
git commit -m "$(cat <<'EOF'
refactor(prefs): migrate hook_runner + audio-hooks CLI onto UserPreferences

Removes the duplicated _resolve_plugin_data_dir / _is_running_from_plugin /
_auto_init_user_prefs / _apply_plugin_option_overlay helpers from both
hooks/hook_runner.py and bin/audio-hooks.py — they now live exclusively in
hooks/user_preferences.py. Module-level globals (CONFIG_FILE, QUEUE_DIR)
are removed; consumers acquire paths via get_prefs() instead.

This eliminates the dual-implementation bug class that caused 5.1.4: a fix
applied to one copy never propagated to the other. The CLI (bin/audio-hooks.py)
and the runtime (hooks/hook_runner.py) now agree on path resolution by
construction.

No user-visible behavior change. All existing tests still pass; the cursor
bridge regression test (5.1.4 anti-stranding) remains green.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

# Phase 3 — `audio-hooks upgrade` + `backup *` subcommands

**Files:**
- Modify: `bin/audio-hooks.py` (add cmd_upgrade + cmd_backup)
- Create: `tests/test_upgrade_command.py`

**Phase commit message:**
```
feat(cli): audio-hooks upgrade + backup subcommands

New JSON CLI verbs replacing the manual "claude plugin uninstall + install"
two-step incantation:

* audio-hooks upgrade [--check-only] [--force]
  - Detects scope via `claude plugin list --json`.
  - First attempts `claude plugin update --scope <scope>` (data-preserving).
  - Falls back to `uninstall --keep-data + install` if update fails.
  - Writes a marker at ~/.claude-audio-hooks-backups/.upgrade_in_progress.json
    so a crashed upgrade leaves recovery instructions in plain JSON.
  - On success, calls prefs.load() to trigger automatic migration.

* audio-hooks backup list / show / restore / prune
  - JSON-emitting; restore round-trips by stamping a backup of the current
    state before overwriting (so AI can undo a wrong restore).
  - Magic IDs: latest, latest-sibling, latest-external, plus exact ISO ts.

Adds error codes BACKUP_FAILED, BACKUP_NOT_FOUND, RESTORE_FAILED,
LOCK_TIMEOUT, NOT_INSTALLED, UPGRADE_UNINSTALL_FAILED,
UPGRADE_REINSTALL_FAILED, UPGRADE_VERIFY_FAILED, PRIOR_UPGRADE_INCOMPLETE.

Manifest output extends with `editor_targets`, `customizations` (output
of prefs.diff_from_default), and `last_migration` (latest config_migrated
NDJSON event, if any).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 3.1 — Backup CLI subcommands

- [ ] **Step 3.1.1: Write failing tests for backup CLI**

Create `tests/test_backup_cli.py`:

```python
"""Tests for `audio-hooks backup *` CLI subcommands."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "bin" / "audio-hooks.py"


def _run_cli(args, *, env_extra=None, cwd=None):
    env = os.environ.copy()
    for k in ("CLAUDE_PLUGIN_DATA", "CLAUDE_AUDIO_HOOKS_DATA", "CLAUDE_PLUGIN_ROOT"):
        env.pop(k, None)
    if env_extra:
        env.update(env_extra)
    env.setdefault("PYTHONIOENCODING", "utf-8")
    proc = subprocess.run(
        [sys.executable, str(SCRIPT)] + list(args),
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        env=env, cwd=cwd, timeout=15,
    )
    return proc.returncode, proc.stdout, proc.stderr


class TestBackupCLI(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fake_home = tempfile.TemporaryDirectory()
        self.env = {
            "CLAUDE_PLUGIN_DATA": self.tmp.name,
            # Force HOME for backup external dir resolution
            "HOME": self.fake_home.name,
            "USERPROFILE": self.fake_home.name,
        }

    def tearDown(self):
        self.tmp.cleanup()
        self.fake_home.cleanup()

    def _seed_two_saves(self):
        """Generate two saves so we have a sibling .bak + 1 external backup."""
        rc, _, _ = _run_cli(["set", "audio_theme", "default"], env_extra=self.env)
        self.assertEqual(rc, 0)
        rc, _, _ = _run_cli(["set", "audio_theme", "custom"], env_extra=self.env)
        self.assertEqual(rc, 0)

    def test_backup_list_returns_json_array(self):
        self._seed_two_saves()
        rc, out, _ = _run_cli(["backup", "list"], env_extra=self.env)
        self.assertEqual(rc, 0)
        doc = json.loads(out.strip())
        self.assertTrue(doc["ok"])
        self.assertIsInstance(doc["backups"], list)
        self.assertGreater(len(doc["backups"]), 0)
        for entry in doc["backups"]:
            self.assertIn("id", entry)
            self.assertIn("location", entry)
            self.assertIn(entry["location"], ("sibling", "external"))

    def test_backup_show_emits_full_content(self):
        self._seed_two_saves()
        rc, list_out, _ = _run_cli(["backup", "list"], env_extra=self.env)
        backups = json.loads(list_out.strip())["backups"]
        first_id = backups[0]["id"]
        rc, out, _ = _run_cli(["backup", "show", first_id], env_extra=self.env)
        self.assertEqual(rc, 0)
        doc = json.loads(out.strip())
        self.assertTrue(doc["ok"])
        self.assertIn("content", doc)
        self.assertIn("audio_theme", doc["content"])

    def test_backup_restore_round_trips(self):
        self._seed_two_saves()
        # We just changed default→custom. Restoring latest-external (which
        # captured the pre-second-save = "default" state) should put us back.
        rc, out, _ = _run_cli(["backup", "restore", "latest-external"], env_extra=self.env)
        self.assertEqual(rc, 0)
        doc = json.loads(out.strip())
        self.assertTrue(doc["ok"])
        # Verify by reading current
        rc, status_out, _ = _run_cli(["status"], env_extra=self.env)
        status = json.loads(status_out.strip())
        self.assertEqual(status["theme"], "default")

    def test_backup_restore_nonexistent_returns_error(self):
        self._seed_two_saves()
        rc, out, _ = _run_cli(["backup", "restore", "9999-01-01T00:00:00.000Z"], env_extra=self.env)
        self.assertNotEqual(rc, 0)
        doc = json.loads(out.strip())
        self.assertFalse(doc["ok"])
        self.assertEqual(doc["error"]["code"], "BACKUP_NOT_FOUND")

    def test_backup_prune_idempotent(self):
        self._seed_two_saves()
        rc, out, _ = _run_cli(["backup", "prune"], env_extra=self.env)
        self.assertEqual(rc, 0)
        doc = json.loads(out.strip())
        self.assertTrue(doc["ok"])
        # Run again — still ok, removed=0
        rc, out, _ = _run_cli(["backup", "prune"], env_extra=self.env)
        doc = json.loads(out.strip())
        self.assertEqual(doc["removed"], 0)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3.1.2: Verify backup CLI tests fail**

```bash
python -m pytest tests/test_backup_cli.py -v
```
Expected: tests fail with "Unknown subcommand: backup" or similar.

- [ ] **Step 3.1.3: Implement cmd_backup in bin/audio-hooks.py**

In `bin/audio-hooks.py`, register a new subcommand. Locate the `SUBCOMMANDS` dict (search `"version": cmd_version,`) and add:

```python
def cmd_backup(args: List[str]) -> int:
    if require_project_root() != 0:
        return 1
    if not args:
        return emit_error("INVALID_USAGE", "Usage: audio-hooks backup <list|show|restore|prune>",
                          suggested_command="audio-hooks manifest")
    sub = args[0]
    rest = args[1:]
    prefs = _prefs()
    if sub == "list":
        try:
            entries = prefs.list_backups()
        except Exception as e:
            return emit_error("INTERNAL_ERROR", str(e))
        emit({"ok": True, "backups": entries, "count": len(entries),
              "external_dir": str(prefs.external_backup_dir),
              "sibling_path": str(prefs.sibling_backup_path)})
        return 0
    if sub == "show":
        if not rest:
            return emit_error("INVALID_USAGE", "Usage: audio-hooks backup show <id>")
        backup_id = rest[0]
        entries = prefs.list_backups()
        match = next((e for e in entries if e["id"] == backup_id), None)
        if match is None:
            return emit_error("BACKUP_NOT_FOUND", f"No backup with id={backup_id}",
                              suggested_command="audio-hooks backup list")
        try:
            content = json.loads(Path(match["path"]).read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            return emit_error("RESTORE_FAILED", f"Backup unreadable: {e}",
                              suggested_command="audio-hooks backup list")
        emit({"ok": True, "id": backup_id, "location": match["location"],
              "from_version": match["from_version"], "content": content})
        return 0
    if sub == "restore":
        if not rest:
            return emit_error("INVALID_USAGE", "Usage: audio-hooks backup restore <id|latest|latest-sibling|latest-external>")
        backup_id = rest[0]
        try:
            restored = prefs.restore_from(backup_id)
        except FileNotFoundError as e:
            return emit_error("BACKUP_NOT_FOUND", str(e),
                              suggested_command="audio-hooks backup list")
        except ValueError as e:
            return emit_error("RESTORE_FAILED", str(e),
                              suggested_command="audio-hooks backup list")
        emit({"ok": True, "restored_from": backup_id,
              "audio_theme": restored.get("audio_theme"),
              "version": restored.get("_version")})
        return 0
    if sub == "prune":
        try:
            removed = prefs.prune_backups()
        except Exception as e:
            return emit_error("INTERNAL_ERROR", str(e))
        emit({"ok": True, "removed": removed,
              "kept_max": _prefs().EXTERNAL_BACKUP_KEEP})
        return 0
    return emit_error("INVALID_USAGE", f"Unknown backup subcommand: {sub}",
                      suggested_command="audio-hooks backup list")
```

Add `"backup": cmd_backup,` to the SUBCOMMANDS dispatch dict.

Add the new error codes to the `_ERROR_HINTS` table at the top of `bin/audio-hooks.py` (and to `hook_runner.py`'s `ErrorCode` enum if used there too):

```python
"BACKUP_FAILED": {"hint": "Backup write failed.", "suggested_command": "audio-hooks diagnose"},
"BACKUP_NOT_FOUND": {"hint": "Backup id not found.", "suggested_command": "audio-hooks backup list"},
"RESTORE_FAILED": {"hint": "Backup file is corrupt or unreadable.", "suggested_command": "audio-hooks backup list"},
"LOCK_TIMEOUT": {"hint": "Could not acquire user_preferences lock.", "suggested_command": "audio-hooks diagnose"},
```

- [ ] **Step 3.1.4: Verify backup CLI tests pass**

```bash
python -m pytest tests/test_backup_cli.py -v
```
Expected: 5 tests PASS.

---

## Task 3.2 — Upgrade CLI subcommand

- [ ] **Step 3.2.1: Write failing tests for upgrade**

Create `tests/test_upgrade_command.py`:

```python
"""Tests for `audio-hooks upgrade` subcommand.

Mocks `claude plugin` invocations via PATH-shim — a fake `claude.cmd`
(Windows) or `claude` (POSIX) bash script in a tempdir prepended to PATH.
This is more portable than mocking subprocess.
"""

from __future__ import annotations

import json
import os
import platform
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "bin" / "audio-hooks.py"


def _make_fake_claude(shim_dir: Path, behaviors: dict):
    """Create a fake `claude` shim that responds to `claude plugin <verb>`
    based on the `behaviors` dict, e.g.:
        {"list": '{"plugins": [{"id": "audio-hooks@chanmeng-audio-hooks", ...}]}',
         "update": "OK", "install": "OK", "uninstall": "OK"}
    """
    if platform.system() == "Windows":
        shim_path = shim_dir / "claude.cmd"
        body = "@echo off\nif \"%2\"==\"list\" (\n"
        body += f"  echo {behaviors.get('list', '[]').replace(chr(34), chr(34)+chr(94)+chr(34)+chr(34))}\n"
        body += "  exit /b 0\n)\n"
        for verb in ("update", "install", "uninstall"):
            body += f"if \"%2\"==\"{verb}\" (\n"
            body += f"  echo {behaviors.get(verb, 'OK')}\n"
            body += f"  exit /b {0 if behaviors.get(verb, 'OK') != 'FAIL' else 1}\n)\n"
        shim_path.write_text(body)
    else:
        shim_path = shim_dir / "claude"
        body = "#!/usr/bin/env bash\n"
        body += "case \"$2\" in\n"
        body += f"  list) cat <<'EOF_LIST'\n{behaviors.get('list', '[]')}\nEOF_LIST\n  ;;\n"
        for verb in ("update", "install", "uninstall"):
            ok = behaviors.get(verb, "OK")
            body += f"  {verb}) echo '{ok}'; exit {0 if ok != 'FAIL' else 1};;\n"
        body += "  *) exit 1;;\n"
        body += "esac\n"
        shim_path.write_text(body)
        shim_path.chmod(stat.S_IRWXU)


class TestUpgradeCommand(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.shim_dir = Path(self.tmp.name) / "shim"
        self.shim_dir.mkdir()
        self.data_dir = Path(self.tmp.name) / "data"
        self.data_dir.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def _run_with_shim(self, args, list_response):
        env = os.environ.copy()
        env["PATH"] = str(self.shim_dir) + os.pathsep + env.get("PATH", "")
        env["CLAUDE_PLUGIN_DATA"] = str(self.data_dir)
        env.setdefault("PYTHONIOENCODING", "utf-8")
        _make_fake_claude(self.shim_dir, {"list": list_response, "update": "OK"})
        return subprocess.run(
            [sys.executable, str(SCRIPT)] + list(args),
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            env=env, timeout=15,
        )

    def test_check_only_emits_versions_and_exits(self):
        list_response = json.dumps([
            {"id": "audio-hooks@chanmeng-audio-hooks", "scope": "local", "version": "5.1.4"}
        ])
        proc = self._run_with_shim(["upgrade", "--check-only"], list_response)
        self.assertEqual(proc.returncode, 0)
        doc = json.loads(proc.stdout.strip())
        self.assertTrue(doc["ok"])
        self.assertEqual(doc["current_version"], "5.1.4")
        self.assertIn("would_upgrade", doc)

    def test_upgrade_when_not_installed_emits_NOT_INSTALLED(self):
        list_response = "[]"
        proc = self._run_with_shim(["upgrade"], list_response)
        self.assertNotEqual(proc.returncode, 0)
        doc = json.loads(proc.stdout.strip())
        self.assertEqual(doc["error"]["code"], "NOT_INSTALLED")


if __name__ == "__main__":
    unittest.main()
```

Note: due to the complexity of fully testing `upgrade` end-to-end with the shim, this file covers smoke-tests; the rest is exercised by manual end-to-end at Phase 5 release time.

- [ ] **Step 3.2.2: Verify upgrade tests fail**

```bash
python -m pytest tests/test_upgrade_command.py -v
```
Expected: tests fail with "Unknown subcommand: upgrade".

- [ ] **Step 3.2.3: Implement cmd_upgrade**

In `bin/audio-hooks.py`, add:

```python
def cmd_upgrade(args: List[str]) -> int:
    if require_project_root() != 0:
        return 1
    check_only = "--check-only" in args
    force = "--force" in args
    PLUGIN_ID = "audio-hooks@chanmeng-audio-hooks"

    # 1. Detect current install state via claude plugin list --json
    try:
        proc = subprocess.run(
            ["claude", "plugin", "list", "--json"],
            capture_output=True, text=True, encoding="utf-8", timeout=30,
        )
    except FileNotFoundError:
        return emit_error("INTERNAL_ERROR",
                          "`claude` CLI not on PATH; cannot upgrade",
                          suggested_command="install Claude Code first")
    if proc.returncode != 0:
        return emit_error("INTERNAL_ERROR",
                          f"`claude plugin list` failed: {proc.stderr.strip()}")
    try:
        plugins = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        return emit_error("INTERNAL_ERROR", f"Cannot parse plugin list: {e}")

    entry = next((p for p in plugins if p.get("id") == PLUGIN_ID), None)
    if entry is None:
        return emit_error("NOT_INSTALLED",
                          f"{PLUGIN_ID} is not installed in any scope",
                          suggested_command="audio-hooks install --plugin")

    current_scope = entry.get("scope", "user")
    current_version = entry.get("version", "unknown")

    # 2. --check-only path
    if check_only:
        emit({
            "ok": True,
            "current_version": current_version,
            "scope": current_scope,
            "would_upgrade": current_version != PROJECT_VERSION,
            "target_version": PROJECT_VERSION,
        })
        return 0

    # 3. Marker
    marker_dir = Path.home() / ".claude-audio-hooks-backups"
    marker_dir.mkdir(parents=True, exist_ok=True)
    marker = marker_dir / ".upgrade_in_progress.json"
    if marker.exists() and not force:
        try:
            existing = json.loads(marker.read_text(encoding="utf-8"))
            return emit_error("PRIOR_UPGRADE_INCOMPLETE",
                              "A previous upgrade did not complete; investigate before retrying",
                              suggested_command="audio-hooks status",
                              previous=existing)
        except (OSError, ValueError):
            pass
    marker.write_text(json.dumps({
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "from_version": current_version,
        "scope": current_scope,
        "recovery_command": f"python {PROJECT_ROOT}/bin/audio-hooks.py upgrade --force",
    }, indent=2), encoding="utf-8")

    # 4. Try `claude plugin update` first (data-preserving)
    update_proc = subprocess.run(
        ["claude", "plugin", "update", PLUGIN_ID, "--scope", current_scope],
        capture_output=True, text=True, timeout=120,
    )
    used_path = "update"
    if update_proc.returncode != 0:
        # 5. Fallback: uninstall --keep-data + install
        uninstall_proc = subprocess.run(
            ["claude", "plugin", "uninstall", PLUGIN_ID, "--keep-data",
             "--scope", current_scope, "-y"],
            capture_output=True, text=True, timeout=60,
        )
        if uninstall_proc.returncode != 0:
            return emit_error("UPGRADE_UNINSTALL_FAILED",
                              uninstall_proc.stderr.strip() or "uninstall failed",
                              suggested_command=f"claude plugin uninstall {PLUGIN_ID} --keep-data --scope {current_scope}")
        install_proc = subprocess.run(
            ["claude", "plugin", "install", PLUGIN_ID, "--scope", current_scope],
            capture_output=True, text=True, timeout=120,
        )
        if install_proc.returncode != 0:
            return emit_error("UPGRADE_REINSTALL_FAILED",
                              install_proc.stderr.strip() or "install failed",
                              suggested_command=f"claude plugin install {PLUGIN_ID} --scope {current_scope}")
        used_path = "uninstall+install"

    # 6. Verify
    verify_proc = subprocess.run(
        ["claude", "plugin", "list", "--json"],
        capture_output=True, text=True, timeout=30,
    )
    if verify_proc.returncode != 0:
        return emit_error("UPGRADE_VERIFY_FAILED",
                          "Could not re-list plugins after upgrade")
    new_plugins = json.loads(verify_proc.stdout)
    new_entry = next((p for p in new_plugins if p.get("id") == PLUGIN_ID), None)
    new_version = new_entry["version"] if new_entry else "unknown"

    # 7. Delete marker
    try:
        marker.unlink()
    except OSError:
        pass

    # 8. Trigger migration
    migration_info = {}
    try:
        prefs = _prefs()
        # Reset cache so next load picks up post-upgrade paths
        from user_preferences import _reset_prefs  # type: ignore
        _reset_prefs()
        prefs = _prefs()
        cfg = prefs.load()
        migration_info = {"current_version": cfg.get("_version")}
    except Exception as e:
        migration_info = {"warning": f"migration_skipped: {e}"}

    emit({
        "ok": True,
        "from_version": current_version,
        "to_version": new_version,
        "scope": current_scope,
        "data_preserved": True,
        "via": used_path,
        "config": migration_info,
    })
    return 0
```

Add `"upgrade": cmd_upgrade,` to the SUBCOMMANDS dispatch dict.

Add error codes to the `_ERROR_HINTS` table:

```python
"NOT_INSTALLED": {"hint": "Plugin is not installed.", "suggested_command": "audio-hooks install --plugin"},
"UPGRADE_UNINSTALL_FAILED": {"hint": "claude plugin uninstall failed during upgrade.", "suggested_command": "claude plugin list"},
"UPGRADE_REINSTALL_FAILED": {"hint": "claude plugin install failed during upgrade fallback.", "suggested_command": "claude plugin install audio-hooks@chanmeng-audio-hooks"},
"UPGRADE_VERIFY_FAILED": {"hint": "Post-upgrade verification failed.", "suggested_command": "claude plugin list --json"},
"PRIOR_UPGRADE_INCOMPLETE": {"hint": "A previous upgrade did not complete.", "suggested_command": "audio-hooks status"},
```

- [ ] **Step 3.2.4: Verify upgrade tests pass**

```bash
python -m pytest tests/test_upgrade_command.py -v
```
Expected: 2 tests PASS (smoke-test only; full e2e covered manually).

---

## Task 3.3 — Manifest extensions + customizations / last_migration in status

- [ ] **Step 3.3.1: Add `customizations` to status output**

In `cmd_status` in `bin/audio-hooks.py`, after the existing `enabled = ...` line, add:

```python
    customizations = {}
    try:
        customizations = _prefs().diff_from_default()
    except Exception:
        pass
```

Add `"customizations": customizations` to the emit() dict.

- [ ] **Step 3.3.2: Add new manifest fields**

In `_build_manifest` in `bin/audio-hooks.py`, add to the SUBCOMMANDS list:

```python
{"name": "upgrade", "args": ["[--check-only]", "[--force]"], "description": "Refresh the plugin code (and ~/.claude/plugins/cache/) without losing config. Tries `claude plugin update` first; falls back to uninstall --keep-data + install."},
{"name": "backup list", "args": [], "description": "JSON array of available backups, newest first"},
{"name": "backup show", "args": ["<id>"], "description": "Print full content of one backup"},
{"name": "backup restore", "args": ["<id|latest|latest-sibling|latest-external>"], "description": "Restore config from a backup; current state is itself backed up before overwrite"},
{"name": "backup prune", "args": [], "description": "Trim external backup dir to EXTERNAL_BACKUP_KEEP=20"},
```

Add new config_keys: nothing new in user_preferences.json schema (already done in 5.1.4).

- [ ] **Step 3.3.3: Run all tests**

```bash
python -m pytest tests/ -v
```
Expected: all tests pass (78+ tests now).

---

## Task 3.4 — Phase 3 commit

- [ ] **Step 3.4.1: End-to-end smoke**

```bash
python bin/audio-hooks.py manifest 2>&1 | python -c "import sys,json; d=json.loads(sys.stdin.read()); print('subcommand count:', len(d['subcommands'])); print('upgrade present:', any(s['name'] == 'upgrade' for s in d['subcommands'])); print('backup present:', any(s['name'].startswith('backup') for s in d['subcommands']))"

python bin/audio-hooks.py upgrade --check-only
python bin/audio-hooks.py backup list
```
Expected: each emits valid JSON; manifest lists upgrade + backup subcommands.

- [ ] **Step 3.4.2: Commit Phase 3**

```bash
git add bin/audio-hooks.py tests/test_backup_cli.py tests/test_upgrade_command.py
git commit -m "$(cat <<'EOF'
feat(cli): audio-hooks upgrade + backup subcommands

[full message from Phase 3 header]
EOF
)"
```

---

# Phase 4 — default flip rollback + stability test baseline

**Files:**
- Modify: `config/default_preferences.json` (revert 3 keys)
- Create: `config/_defaults_baseline.json` (snapshot)
- Create: `tests/test_defaults_stability.py`

**Phase commit message:**
```
fix(defaults): revert 5.1.4 default flips + add stability test baseline

Three keys had their defaults flipped from false to true in 5.1.4 with no
migration logic to protect users whose data dirs were wiped:
  - enabled_hooks.subagent_stop
  - enabled_hooks.permission_denied
  - enabled_hooks.task_created

5.1.4 users who had been customising audio-hooks for months suddenly
heard 3x more audio after their data dirs were innocently wiped by an
ill-flagged `claude plugin uninstall`. This commit:

1. Reverts those three defaults back to false. (Existing user_preferences.json
   files where the user EXPLICITLY set them to true via 5.1.4 are NOT
   touched — the migration rule preserves user values.)

2. Pins config/_defaults_baseline.json as a snapshot of the post-revert
   default_preferences.json.

3. Adds tests/test_defaults_stability.py — a CI-enforced policy check
   that fails any future PR which flips an existing default's value
   without simultaneously updating _defaults_baseline.json. Set-equality
   comparison for arrays (allowing reordering); scalar equality for
   leaves; recursion into nested dicts.

This makes "no default flip" a code-review-time policy, not a vibes-based
one.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 4.1 — Revert default flips

- [ ] **Step 4.1.1: Edit config/default_preferences.json**

Modify these three lines (search for each):

- Find: `"subagent_stop": true,`  Replace with: `"subagent_stop": false,`
- Find: `"permission_denied": true,`  Replace with: `"permission_denied": false,`
- Find: `"task_created": true,`  Replace with: `"task_created": false,`

- [ ] **Step 4.1.2: Verify**

```bash
python -c "import json; d=json.load(open('config/default_preferences.json')); print({k: d['enabled_hooks'][k] for k in ('subagent_stop','permission_denied','task_created')})"
```
Expected: `{'subagent_stop': False, 'permission_denied': False, 'task_created': False}`.

---

## Task 4.2 — Create baseline snapshot

- [ ] **Step 4.2.1: Copy default_preferences.json verbatim**

```bash
cp config/default_preferences.json config/_defaults_baseline.json
```

- [ ] **Step 4.2.2: Verify**

```bash
diff config/default_preferences.json config/_defaults_baseline.json
```
Expected: empty diff.

---

## Task 4.3 — Stability test

- [ ] **Step 4.3.1: Write the test**

Create `tests/test_defaults_stability.py`:

```python
"""Defaults stability test: every existing default value pinned in
config/_defaults_baseline.json must survive in config/default_preferences.json.

New keys in default_preferences.json are allowed.
Removed keys are allowed (deprecation).
Flipped scalar values are FORBIDDEN.
Reordered arrays are allowed (set-equality compare).
Element changes in arrays are FORBIDDEN.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from typing import Any, List, Tuple

REPO = Path(__file__).resolve().parent.parent
TEMPLATE = REPO / "config" / "default_preferences.json"
BASELINE = REPO / "config" / "_defaults_baseline.json"

METADATA_KEYS = ("_version", "version", "$schema")
COMMENT_PREFIX = "_"


def _walk_for_diff(
    template: Any,
    baseline: Any,
    path: str = "",
    flips: List[Tuple[str, Any, Any]] = None,
) -> List[Tuple[str, Any, Any]]:
    if flips is None:
        flips = []
    if isinstance(baseline, dict):
        if not isinstance(template, dict):
            flips.append((path, baseline, template))
            return flips
        for k, b_val in baseline.items():
            if k in METADATA_KEYS or k.startswith(COMMENT_PREFIX):
                continue
            if k not in template:
                continue  # removed key, allowed
            full = f"{path}.{k}" if path else k
            _walk_for_diff(template[k], b_val, full, flips)
    elif isinstance(baseline, list):
        # Set-equality with scalars; FAIL if elements differ
        if not isinstance(template, list):
            flips.append((path, baseline, template))
            return flips
        if set(map(_hashable, baseline)) != set(map(_hashable, template)):
            flips.append((path, baseline, template))
    else:
        if baseline != template:
            flips.append((path, baseline, template))
    return flips


def _hashable(v):
    if isinstance(v, (list, dict)):
        return json.dumps(v, sort_keys=True)
    return v


class TestDefaultsStability(unittest.TestCase):
    def test_no_existing_default_was_flipped(self):
        template = json.loads(TEMPLATE.read_text(encoding="utf-8"))
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
        flips = _walk_for_diff(template, baseline)
        if flips:
            msg = "Default value flip(s) detected — update _defaults_baseline.json AND CHANGELOG if intentional:\n"
            for path, old, new in flips:
                msg += f"  {path}: {old!r} -> {new!r}\n"
            self.fail(msg)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 4.3.2: Run the test**

```bash
python -m pytest tests/test_defaults_stability.py -v
```
Expected: PASS (template == baseline).

- [ ] **Step 4.3.3: Verify the test catches a flip**

Temporarily edit `config/default_preferences.json`, change `"audio_theme": "default"` to `"audio_theme": "custom"`. Run:

```bash
python -m pytest tests/test_defaults_stability.py -v
```
Expected: FAIL with "audio_theme: 'default' -> 'custom'". Revert the edit.

- [ ] **Step 4.3.4: Run full suite**

```bash
python -m pytest tests/ -v
```
Expected: all tests pass.

---

## Task 4.4 — Phase 4 commit

- [ ] **Step 4.4.1: Commit**

```bash
git add config/default_preferences.json config/_defaults_baseline.json tests/test_defaults_stability.py
git commit -m "$(cat <<'EOF'
fix(defaults): revert 5.1.4 default flips + add stability test baseline

[full message from Phase 4 header]
EOF
)"
```

---

# Phase 5 — release: plugin sync, docs, version bumps, tag

**Files modified:**
- `scripts/build-plugin.sh` (run; copies canonical → plugin layout)
- `plugins/audio-hooks/.claude-plugin/plugin.json` (version → 5.1.5)
- `bin/audio-hooks.py` (PROJECT_VERSION → 5.1.5)
- `hooks/hook_runner.py` (HOOK_RUNNER_VERSION → 5.1.5)
- `config/default_preferences.json` (`_version` → 5.1.5)
- `config/_defaults_baseline.json` (`_version` → 5.1.5)
- `CHANGELOG.md` (5.1.5 entry)
- `CLAUDE.md` (decision tree + version table)
- `README.md` (What's new line, version badge)
- `plugins/audio-hooks/skills/audio-hooks/SKILL.md` (upgrade section)

**Phase commit message:**
```
chore(release): v5.1.5 — painless upgrades

Highlights documented in CHANGELOG.md.
```

Tag at the end: `git tag v5.1.5`.

---

## Task 5.1 — Bump versions

- [ ] **Step 5.1.1: Update PROJECT_VERSION in bin/audio-hooks.py**

Find: `PROJECT_VERSION = "5.1.4"`  Replace with: `PROJECT_VERSION = "5.1.5"`

- [ ] **Step 5.1.2: Update HOOK_RUNNER_VERSION in hooks/hook_runner.py**

Find: `HOOK_RUNNER_VERSION = "5.1.4"`  Replace with: `HOOK_RUNNER_VERSION = "5.1.5"`

- [ ] **Step 5.1.3: Update _version in default_preferences.json + baseline**

In `config/default_preferences.json` and `config/_defaults_baseline.json`:
- Find: `"_version": "5.1.4"`  Replace with: `"_version": "5.1.5"`
- Find: `"version": "5.1.4"`  Replace with: `"version": "5.1.5"`
- Find: `"_comment": "Claude Code Audio Hooks - Default Configuration Template (v5.1.4)"`  Replace: `"... (v5.1.5)"`

- [ ] **Step 5.1.4: Update plugin.json version**

In `plugins/audio-hooks/.claude-plugin/plugin.json`:
- Find: `"version": "5.1.4"`  Replace: `"version": "5.1.5"`

- [ ] **Step 5.1.5: Verify**

```bash
python bin/audio-hooks.py version
```
Expected: `{"ok":true,"version":"5.1.5","hook_runner_version":"5.1.5",...}`

---

## Task 5.2 — Sync plugin layout

- [ ] **Step 5.2.1: Run build-plugin.sh**

```bash
bash scripts/build-plugin.sh
```
Expected: `{"ok":true,"copied":N,...}` for some N>0.

- [ ] **Step 5.2.2: Verify in-sync**

```bash
bash scripts/build-plugin.sh --check
```
Expected: `{"ok":true,"in_sync":true,...}`

---

## Task 5.3 — CHANGELOG entry

- [ ] **Step 5.3.1: Prepend new entry**

Insert at the top of `CHANGELOG.md`, just below the project header, BEFORE the existing `## [5.1.4]` section:

```markdown
## [5.1.5] - 2026-05-01

> **⚠️ For users who got bit by 5.1.4.** If your `audio_hooks` was reinitialised under 5.1.4 (e.g., via a `claude plugin uninstall` without `--keep-data`) and you now hear `subagent_stop` / `permission_denied` / `task_created` audio you didn't want, run: `audio-hooks hooks disable subagent_stop permission_denied task_created`. Migration logic from 5.1.5 forward will preserve your choice across all future upgrades.

Painless upgrades. New `UserPreferences` class as single source of truth eliminates the dual-implementation bug class. `audio-hooks upgrade` wraps `claude plugin update`/`uninstall+install` with `--keep-data`. Auto-migration on load preserves user values when new keys are added in future versions. Dual-location backups (`~/.claude/plugins/data/<id>/user_preferences.json.bak` for last-good + `~/.claude-audio-hooks-backups/<id>/<ts>.json` for disaster recovery, rotation=20). New `audio-hooks backup list/show/restore/prune` subcommands. New `config/_defaults_baseline.json` + `tests/test_defaults_stability.py` enforce a no-default-flip policy at CI. The 5.1.4 default flips for `subagent_stop`, `permission_denied`, `task_created` are reverted to false.

### Fixed

- **Existing users no longer lose configuration on `claude plugin uninstall + install`** (the path 5.1.4 documented as "do this once to refresh the cache"). The new `audio-hooks upgrade` subcommand drives that flow with `--keep-data` automatically.
- **Default value flips between versions are now CI-enforced policy violations.** `tests/test_defaults_stability.py` snapshots `config/default_preferences.json` into `config/_defaults_baseline.json`; flipping any existing scalar default fails the test until the baseline is also updated.
- **5.1.4 default flips reverted.** `enabled_hooks.subagent_stop`, `enabled_hooks.permission_denied`, `enabled_hooks.task_created` go back to `false`. Existing users who explicitly set these to `true` in 5.1.4 are unaffected (migration preserves user values).

### Added

- **`hooks/user_preferences.py`** — single source of truth for user_preferences.json. ~350 lines. Owns path resolution (6-level chain), load with auto-migration, save with auto-backup, atomic writes guarded by cross-platform file lock, dual-location backup management, `diff_from_default()` for surfacing user customizations, lazy `get_prefs()` singleton.
- **Auto-migration on load.** When `user_preferences.json` `_version` differs from the bundled template's, deep-merge missing keys without overwriting existing user values. Lists are atomic (user list wins entirely). Scalar-vs-container type mismatch resets to template default. `_version` and comment fields always overwrite from template. Migration is logged to NDJSON as `action: config_migrated` with `from_version`, `to_version`, `added_keys`, `backup_id`.
- **Dual-location backups on save.** Every save snapshots the prior file content to `<data_dir>/user_preferences.json.bak` (last good, overwritten on each save) AND to `~/.claude-audio-hooks-backups/<plugin_id>/<ts>.json` (disaster recovery, kept outside `~/.claude/plugins/data/` so `claude plugin uninstall` cannot wipe it). Rotation: keep 20 most recent. Dedup: skip backup when content is byte-identical to the latest. Atomic write via `os.replace()`. Cross-platform file lock (`fcntl.flock` POSIX, `msvcrt.locking` Windows) on `<data_dir>/.user_prefs.lock` prevents concurrent saves from racing.
- **`audio-hooks upgrade [--check-only] [--force]`** — JSON CLI verb that replaces the manual "uninstall + install" two-step. Detects scope via `claude plugin list --json`. Tries `claude plugin update` first; falls back to `uninstall --keep-data + install`. Crash-mid-upgrade leaves a marker at `~/.claude-audio-hooks-backups/.upgrade_in_progress.json` with full recovery instructions. On success, calls `prefs.load()` to trigger automatic migration.
- **`audio-hooks backup list / show / restore / prune`** — JSON-emitting backup management. `restore` itself stamps a backup of the current state before overwriting (so a wrong restore is reversible). Magic IDs: `latest`, `latest-sibling`, `latest-external`, plus exact ISO timestamp for external backups.
- **`status` / `manifest` output extensions.** New `customizations` block (output of `prefs.diff_from_default()`) shows only the keys where the user differs from defaults. New `last_migration` block (latest `config_migrated` NDJSON event, if any).
- **New stable error codes.** `BACKUP_FAILED`, `BACKUP_NOT_FOUND`, `RESTORE_FAILED`, `LOCK_TIMEOUT`, `NOT_INSTALLED`, `UPGRADE_UNINSTALL_FAILED`, `UPGRADE_REINSTALL_FAILED`, `UPGRADE_VERIFY_FAILED`, `PRIOR_UPGRADE_INCOMPLETE`. Each carries a `hint` and `suggested_command` so AI can self-recover.
- **40+ new unit tests** in `tests/test_user_preferences.py`, `tests/test_migration.py`, `tests/test_backups.py`, `tests/test_backup_cli.py`, `tests/test_upgrade_command.py`, `tests/test_defaults_stability.py`. All stdlib-only.

### Refactored

- `hooks/hook_runner.py` and `bin/audio-hooks.py` consolidated onto `UserPreferences`. Deleted ~200 lines of duplicated helpers (`_resolve_plugin_data_dir`, `_is_running_from_plugin`, `_auto_init_user_prefs`, `_apply_plugin_option_overlay`, plus the diverged `_resolve_config_file`/`_config_path` pair). Module-level globals (`CONFIG_FILE`, `QUEUE_DIR`) removed; consumers now call `_prefs().config_path` etc. This eliminates the dual-implementation bug class that caused 5.1.4 to need a follow-up patch.

```

- [ ] **Step 5.3.2: Run pytest one more time**

```bash
python -m pytest tests/ -v
```
Expected: all tests pass.

---

## Task 5.4 — CLAUDE.md update

- [ ] **Step 5.4.1: Bump header version**

Find: `> **Version:** 5.1.4 | **Last Updated:** 2026-05-01`  Replace: `> **Version:** 5.1.5 | **Last Updated:** 2026-05-01`

- [ ] **Step 5.4.2: Add 5.1.5 row to version history table**

Find the row starting with `| 5.1.4 | 2026-05-01 |`. Insert ABOVE it:

```markdown
| 5.1.5 | 2026-05-01 | **Painless upgrades.** New `UserPreferences` class as single source of truth eliminates the dual-implementation bug. `audio-hooks upgrade` wraps `claude plugin update`/`uninstall+install` with `--keep-data` automatically. Auto-migration on load preserves user values when future versions add new keys. Dual-location backups survive `claude plugin uninstall`. `audio-hooks backup list/show/restore/prune` subcommands. New `config/_defaults_baseline.json` + `tests/test_defaults_stability.py` enforce no-default-flip policy at CI. 5.1.4 default flips for `subagent_stop` / `permission_denied` / `task_created` are reverted. |
```

- [ ] **Step 5.4.3: Update decision tree rows**

Find existing decision-tree rows. Replace the row about "Cursor 还在播放老主题" with:

```markdown
| "Cursor 还在播放老主题" / "刷新缓存" / "升级 audio-hooks" | `audio-hooks upgrade`. Auto-detects scope and uses `claude plugin update` (data-preserving) with fallback to `uninstall --keep-data + install`. Replaces the 5.1.4 manual `/plugin uninstall + install` recipe. |
```

Add new rows before the uninstall row:

```markdown
| "看上次升级是什么时候 / 我改过哪些配置" | `audio-hooks status`. New `customizations` field shows only your customizations (audio_theme, enabled_hooks deltas, webhook config, etc.). New `last_migration` shows the most recent automatic config migration. |
| "我搞砸了 / 想恢复昨天的配置" | `audio-hooks backup list` lists available backups (sibling .bak + external timestamped, last 20). `audio-hooks backup restore <id>` restores; the current state is itself backed up first so the restore is reversible. |
| "备份文件占空间" | `audio-hooks backup prune`. Idempotent — keeps 20 most recent. Each backup is ~9 KB. |
```

---

## Task 5.5 — README + SKILL updates

- [ ] **Step 5.5.1: README.md**

Update version badge: `version-5.1.4` → `version-5.1.5`.

Replace the current "5.1.4 — Cursor IDE compatibility" line with:

```markdown
**🆕 5.1.5 — Painless upgrades.** Existing users never lose config across upgrades. New `audio-hooks upgrade` wraps `claude plugin update` / `uninstall + install` with `--keep-data` automatically; auto-migration preserves your settings when new keys are added in future versions; dual-location backups survive even rough `claude plugin uninstall`. Run it any time you want to refresh the plugin code Cursor's bridge invokes. See [CHANGELOG](./CHANGELOG.md#515---2026-05-01).
```

- [ ] **Step 5.5.2: SKILL.md**

In `plugins/audio-hooks/skills/audio-hooks/SKILL.md`, add a new section after the existing "Snooze / mute / quiet hours" section:

```markdown
**Upgrade the plugin without losing config**

`audio-hooks upgrade` is the AI-first way to refresh the plugin code (and `~/.claude/plugins/cache/`) without touching the user's preferences. Use it whenever:

| User says | Run |
|---|---|
| "upgrade audio-hooks" / "refresh the cache" / "Cursor still plays old theme" | `audio-hooks upgrade` |
| "is there a new version?" | `audio-hooks upgrade --check-only` |
| "the upgrade got stuck" | `audio-hooks upgrade --force` (only after confirming via `audio-hooks status`) |

`upgrade` auto-detects scope via `claude plugin list --json`, tries `claude plugin update` first (data-preserving), falls back to `uninstall --keep-data + install` if needed. On success, the user's `~/.claude/plugins/data/audio-hooks-chanmeng-audio-hooks/user_preferences.json` is preserved verbatim, then loaded through auto-migration so new keys from the new template are merged in non-destructively.

**Restore from a backup**

| User says | Run |
|---|---|
| "what configurations have I changed?" | `audio-hooks status` (look at the `customizations` field) |
| "show me available backups" | `audio-hooks backup list` |
| "restore my config from before the upgrade" | `audio-hooks backup restore latest-external` |
| "delete old backups" | `audio-hooks backup prune` |
```

---

## Task 5.6 — Final commit + tag

- [ ] **Step 5.6.1: Verify all tests pass**

```bash
python -m pytest tests/ -v
bash scripts/build-plugin.sh --check
```
Expected: tests all green; plugin layout in sync.

- [ ] **Step 5.6.2: Commit Phase 5**

```bash
git add bin/audio-hooks.py hooks/hook_runner.py config/default_preferences.json config/_defaults_baseline.json plugins/ CHANGELOG.md CLAUDE.md README.md
git commit -m "$(cat <<'EOF'
chore(release): v5.1.5 — painless upgrades

Highlights documented in CHANGELOG.md. Five focused commits on this
feature branch implement the painless-upgrades design at
docs/specs/2026-05-01-painless-upgrades-design.md:

  Phase 1: feat(prefs): add UserPreferences class as single source of truth
  Phase 2: refactor(prefs): migrate hook_runner + audio-hooks CLI onto UserPreferences
  Phase 3: feat(cli): audio-hooks upgrade + backup subcommands
  Phase 4: fix(defaults): revert 5.1.4 default flips + add stability test baseline
  Phase 5: chore(release): v5.1.5 — painless upgrades  (this commit)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5.6.3: Tag the release**

```bash
git tag -a v5.1.5 -m "v5.1.5 — painless upgrades"
git log --oneline -6
```
Expected: 5 phase commits + the tag.

- [ ] **Step 5.6.4: Smoke test the released CLI**

```bash
python bin/audio-hooks.py version
python bin/audio-hooks.py status
python bin/audio-hooks.py manifest 2>&1 | python -c "import sys,json; print('subcommand count:', len(json.loads(sys.stdin.read())['subcommands']))"
python bin/audio-hooks.py upgrade --check-only
python bin/audio-hooks.py backup list
```
Expected: all emit valid JSON. `version` shows 5.1.5. `manifest` lists upgrade + backup. `upgrade --check-only` shows current and target versions. `backup list` returns the sibling .bak from earlier saves (and external if any).

- [ ] **Step 5.6.5: Final pretty git log**

```bash
git log --oneline feat/painless-upgrades-5.1.5 ^master
```
Expected: 5 commits visible on the feature branch ahead of master, in this order:
```
<sha> chore(release): v5.1.5 — painless upgrades
<sha> fix(defaults): revert 5.1.4 default flips + add stability test baseline
<sha> feat(cli): audio-hooks upgrade + backup subcommands
<sha> refactor(prefs): migrate hook_runner + audio-hooks CLI onto UserPreferences
<sha> feat(prefs): add UserPreferences class as single source of truth
```

---

## Post-merge (manual, not part of the plan)

After this branch merges to `master`:
- The user runs `audio-hooks upgrade` exactly once to migrate from 5.1.4 to 5.1.5.
- All future `audio-hooks upgrade` invocations are non-destructive.
- Future PRs that touch `config/default_preferences.json` must update `config/_defaults_baseline.json` in the same commit OR the stability test fails.
