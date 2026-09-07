---
summary: "Conditional engineering notes for the retained full upstream CodexBar build."
read_when:
  - Changing the full upstream app, providers or widgets
  - Packaging or releasing the full upstream app
---

# Full upstream CodexBar notes

These notes apply to the retained full app. The default Lite workflow is in [AGENTS.md](../AGENTS.md) and [README.md](../README.md).

## Source and checks

- Full app sources live in `Sources/CodexBar`; provider/parser tests live in `Tests/CodexBarTests`.
- Select the full package with `CODEXBAR_FULL=1`. Use `make test-full` for the sharded suite and `make check-full` for full formatting/lint checks before handing off full-app code changes. Add focused full-package `swift test --filter ...` runs when they help diagnose parser/provider fixes.
- Full-build dependency versions are pinned with `exact:` in `Package.swift`, including the
  otherwise transitive `swift-asn1`. There is no committed lockfile: `Package.swift` returns a
  different package per `CODEXBAR_FULL`, SwiftPM keeps one `Package.resolved` slot, and it
  discards a lockfile whose `originHash` does not match the manifest being evaluated. Bump a
  dependency by editing its pin here, then re-resolve and run `make check-full`.
- XCTest files use `FeatureNameTests` and `test_caseDescription` methods. Preserve the root Swift and credential constraints.
- Use focused CLI/parser/settings tests when they can prove the behavior. Avoid packaging or relaunching merely to validate logic.
- App-group migration tests must inject dictionary-backed defaults, both snapshot URLs, a synthetic home and a contained recording FileManager. UUID defaults suites and Keychain isolation flags do not isolate defaults search domains or filesystem access. Ordinary SettingsStore tests must not discover shared defaults or run app-group migration.
- For Keychain-related tests use stubs, test stores or `KeychainNoUIQuery`. Live provider probes, browser-cookie imports, `codexbar usage` against real accounts and real SecItem reads require an explicit live-testing request.
- macOS CI is brittle around headless AppKit status/menu tests. Prefer stable seams such as `MenuDescriptor`, `ProvidersPane` and `CodexAccountsSectionState`, unless AppKit wiring is the behavior under test.

## Bundle and UI validation

- `CODEXBAR_FULL=1 ./Scripts/compile_and_run.sh` builds, packages, relaunches `CodexBar.app` and checks that it stays running. Add `--test` to run the sharded suite. Use this only for required bundle/UI validation.
- `CODEXBAR_FULL=1 ./Scripts/package_app.sh` refreshes the full app bundle. To restart that bundle from the repository root:

  ```bash
  pkill -x CodexBar || pkill -f 'CodexBar.app/Contents/MacOS/CodexBar' || true
  open -n "$PWD/CodexBar.app"
  ```

- Verify the visible target icon and display bounds before menu automation; inspect screenshots rather than trusting a click helper's success alone.
- Widget/Tahoe behavior needs the matching macOS environment; the existing workflow uses a Parallels macOS VM with screenshots/clicks.
- Keep provider identities/plans siloed. Claude CLI status lines are user-configurable and are not a default usage source. An explicit opt-in statusLine JSON feed must be off by default, clearly labeled and fail soft on format drift (owner ruling #2733).
- When cookie import is requested, default to Chrome-only where possible to avoid other browser prompts; use an explicit browser list when needed.

## Full-app release

- Read [RELEASING.md](RELEASING.md) before release work. Full-app release entrypoint: `Scripts/release.sh`; signing/notarization: `Scripts/sign-and-notarize.sh`; appcast: `Scripts/make_appcast.sh`.
- `.mac-release.env` holds release metadata. `Scripts/mac-release` resolves `MAC_RELEASE_TOOL` or the shared `agent-scripts` checkout. Keep generated root zips and appcast changes within release work.
- Keep the release script in the foreground and wait for completion.
- Sparkle signing must use `.mac-release.env` `MAC_RELEASE_SIGNING_KEY_FILE` and the existing CodexBar key. Do not substitute `sparkle-private-key-KEEP-SECURE.txt`, which belongs to VibeTunnel. Never print signing or account secret material.
- The retained release skill references the original maintainer's credential helpers and tap. Resolve release ownership and available credentials before using those locators; Lite packaging uses `make release`.
