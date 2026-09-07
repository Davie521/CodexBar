---
name: codexbar
description: "Read usage, credits, and config health through the retained full upstream CodexBar CLI; return redacted JSON."
---

# CodexBar

Read CodexBar. Never mutate config/auth.

## Run

Run from the CodexBar repository root using this skill's bundled wrapper.

```bash
skill=".agents/skills/codexbar"
"$skill/scripts/codexbar" doctor
"$skill/scripts/codexbar" providers
"$skill/scripts/codexbar" usage
"$skill/scripts/codexbar" usage --provider codex
"$skill/scripts/codexbar" usage --all
```

All stdout: JSON. Upstream CodexBar shape kept. Less drift, fewer tokens.

## Rules

- Start `doctor` when install/config unknown.
- `usage` reads enabled providers. Prefer this.
- `usage --provider ID` reads one provider.
- `usage --all` expensive; use only when needed.
- Identities hidden by default. `--include-identities` only when user explicitly needs them.
- Secrets always hidden.
- Helper read-only: fixed allowlist only. No config writes, auth repair, enable/disable, key storage.
- Timeout means upstream stuck. Narrow provider or raise `CODEXBAR_TIMEOUT` (default 120 seconds).

## Binary

Auto-find: `CODEXBAR_BIN`, PATH, app bundle, Homebrew cask. If missing: open CodexBar, Preferences > Advanced > Install CLI; or set `CODEXBAR_BIN`.

Each stdout/stderr stream capped at 1 MiB while fully drained. Timeout kills process group.
