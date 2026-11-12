# Changelog

All notable changes to Payday will be documented here. The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and intends to use [Semantic Versioning](https://semver.org/) once tagged releases begin.

## [Unreleased]

### Changed

- Android 1.0.2 moves Mac import into a compact pair of text actions alongside backup export near the bottom of Settings.

### Fixed

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
