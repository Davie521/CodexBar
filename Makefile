SHELL := /bin/bash

.PHONY: build check docs-list format lint release restart start start-debug start-release stop test test-full check-full test-live test-tty

start:
	./Scripts/package_lite.sh
	open "CodexBar Lite.app"

start-debug:
	swift run CodexBarLite

start-release: start

restart: start

stop:
	pkill -x CodexBarLite || true

check lint:
	swiftformat Package.swift Sources/CodexBarLite Sources/CodexBarLiteCore Tests/CodexBarLiteTests --lint
	swiftlint lint --strict --quiet Sources/CodexBarLite Sources/CodexBarLiteCore Tests/CodexBarLiteTests
	bash -n Scripts/package_lite.sh
	plutil -lint Resources/Lite-Info.plist

check-full:
	CODEXBAR_FULL=1 ./Scripts/lint.sh lint

format:
	swiftformat Package.swift Sources/CodexBarLite Sources/CodexBarLiteCore Tests/CodexBarLiteTests

docs-list:
	node Scripts/docs-list.mjs

build:
	swift build

test:
	swift test

test-full:
	CODEXBAR_FULL=1 ./Scripts/test.sh

test-tty:
	CODEXBAR_FULL=1 CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 swift test --filter TTYIntegrationTests

test-live:
	CODEXBAR_FULL=1 LIVE_TEST=1 CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS=1 swift test --filter LiveAccountTests

release:
	./Scripts/package_lite.sh
