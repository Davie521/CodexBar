# CodexBar Lite

This fork defaults to the Codex-only Lite app. `Package.swift` selects the retained full upstream package only with `CODEXBAR_FULL=1`.

## Working area

- `Sources/CodexBarLite`: AppKit/SwiftUI menu and quota panel.
- `Sources/CodexBarLiteCore`: credential parsing, usage requests and quota normalization.
- `Tests/CodexBarLiteTests`: focused tests with synthetic credentials and stub transports.
- `Scripts/package_lite.sh`, `Resources/Lite-Info.plist`: Lite packaging and bundle metadata.
- Lite requires macOS 14+ and Swift 6.2+; its default package has no third-party dependencies. Preserve that platform baseline.
- When changing the full app, its providers, widgets or upstream release process, read [full-build notes](docs/agent-upstream.md). The retained `.agents/skills/` workflows target that full app.

## Commands

Run from the repository root. `Makefile` is the command source of truth.

| Task | Command |
| --- | --- |
| Build / focused test | `swift build` / `swift test --filter <test>` |
| Lite tests / checks | `make test` / `make check` |
| Format changed Lite code | `make format` |
| Package Lite | `make release` |
| Build and launch / restart Lite | `make start` / `make restart` |
| Full upstream build / tests / checks | `CODEXBAR_FULL=1 swift build` / `make test-full` / `make check-full` |

For Lite code changes, run `make test` and `make check` before handoff. Documentation-only changes need link/content checks. Package or relaunch only when bundle/UI behavior needs validation.

## Runtime and credentials

- Lite reads Codex file credentials without writing credentials or refreshing tokens. Keep account identity and quota data from the same provider; missing quota remains unavailable, never 100% remaining.
- Tests and ad hoc validation must not access real accounts, import browser cookies, read real Keychain items or display Keychain prompts unless explicitly requested. Use synthetic credentials, stub transports and isolated stores.
- For offline visual checks, use the built Lite binary with `--render-preview <png>` or launch the bundle with `--demo`; `--demo-additional-limits` exercises additional allowances. These paths avoid credential access. See [README](README.md) for invocation details.
- Validate the freshly built bundle. Capture the target display and verify the menu icon is visibly onscreen before clicks; out-of-bounds coordinates or hidden menu extras are not click evidence.

## Swift constraints

- Preserve intentional explicit `self`, existing `MARK` organization and formatter/linter conventions. Use `@Observable`, `@State` ownership and `@Bindable` for new observable SwiftUI state.
- Use released or clearly fictitious model names in code/tests. Swift Testing names should be backticked sentences.
- Review sibling `async let` tasks carefully when one result is required and another is best-effort. Use sequential awaits or a drained throwing task group that contains optional failures; investigate nearby `async let` when crashes mention `swift_task_dealloc` or `asyncLet_finish_after_task_completion`.
- Prefer stable state/model tests over headless AppKit menu construction unless the AppKit wiring itself is under test. Report the commands run and relevant UI evidence with the change.
