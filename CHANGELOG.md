# Changelog

All notable changes to Payday will be documented here. The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and intends to use [Semantic Versioning](https://semver.org/) once tagged releases begin.

## [Unreleased]

### Changed

- Android 1.0.2 moves Mac import into a compact pair of text actions alongside backup export near the bottom of Settings.

### Fixed

- macOS 1.1.1 exposes **New paycheck** beside the heading, guides earlier-month drafts to the current month, and preserves interrupted-allocation blocks when starting over. A failed refresh no longer leaves an earlier snapshot displayed beside a new draft.
- Android 1.0.3 exposes **New paycheck** at the top of Paycheck, confirms before replacing a saved draft, and explains how to recover from an earlier-month draft before using Ready to Assign.
- Android 1.0.1 preserves document-picker results through fingerprint/screen-lock authentication, so Mac import opens its preview after unlocking and backup export resumes correctly.

### Added

- Personal Android app with automatic decimal entry, fingerprint/screen-lock authentication, YNAB allocation, practice mode, and recovery history.
- Mac **Export for Android** and Android import preview for defaults, draft, and full history, with conflict checks and credential-free transfer files.
- Android backup export, private APK signing, core/API/device tests, and Android CI checks.
- Native macOS paycheck allocation workflow with reusable, ordered defaults and one-off contributions.
- Exact integer-money validation, Ready to Assign checks, explicit review, and sequential verified YNAB assignments.
- Durable SQLite operation journal, duplicate protection, interruption recovery, reconciliation evidence, and history export.
- Keychain-backed credentials, isolated Practice Mode, HTTP contract tests, and native app packaging.

No public binary release has been made.
