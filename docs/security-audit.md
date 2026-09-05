# Security audit

**Audited:** 2026-09-05

**Scope:** Swift sources, SQLite persistence and locking, YNAB HTTP boundary, Keychain handling, recovery protocol, packaging scripts, tests, CI, and repository contents

**Method:** Manual source and threat-model review; clean dependency inspection; secret-pattern and artifact scan; warnings-as-errors build; automated tests; package construction; and Practice Mode boundary review

## Executive result

No known critical or high-severity issue was found. Payday's financial-write protocol is deliberately fail-closed: it persists the immutable claim and write intent before network mutation, serializes local writers, refuses automatic write retries, distinguishes ambiguous requests from success, and verifies the final remote state. Credentials are Keychain-backed and production requests are direct HTTPS calls to the fixed YNAB API origin with redirects disabled.

The source is suitable for a private open-source staging repository. Public source publication does not itself create a shared integration. Public distribution of signed binaries remains a separate release gate requiring Developer ID signing/notarization, an OAuth/YNAB integration decision for other users, and another release-specific assessment.

## Threat model

Protected assets are the YNAB token, allocation intent, category assignments, local financial history, and the user's ability to distinguish complete, partial, and unknown outcomes.

In scope are malformed or unexpected API responses, transport interruption, duplicate UI actions, relaunch during a write, two Payday processes, stale drafts, concurrent YNAB edits, insufficient funds, corrupt local state, accidental secret publication, and dependency/CI compromise.

Malicious code already running as the same macOS user, a compromised OS or Keychain, physical access to an unlocked Mac, deliberate database tampering, and restoration of an old database are outside the guarantee. They remain relevant residual risks and are documented to users.

## Control review

| Area | Evidence and result |
| --- | --- |
| Credential storage | Token uses macOS Keychain with `WhenUnlockedThisDeviceOnly`; it is not placed in SQLite, exports, CLI arguments, or logs. Pass. |
| Network boundary | Production base URL is fixed to `https://api.ynab.com/v1`; an ephemeral session disables cache/cookies; redirects are rejected; non-HTTP and wrong-host responses fail. Pass. |
| Money arithmetic | Integer YNAB milliunits are used and currency precision is validated; floating-point money is avoided. Pass. |
| Pre-write validation | Exact allocation, nonnegative/unique contributions, explicit month, Ready to Assign, category eligibility, baseline assignments, identity, and rate-limit budget are checked. Pass. |
| Durable intent | SQLite `BEGIN IMMEDIATE`, full synchronous commits, owner-only modes, a no-follow process lock, and intent-before-send ordering protect the local journal. Pass. |
| Duplicate/partial writes | Durable identities and aliases, UI busy state, cross-process lock, per-step states, no automatic write retry, final reread, and blocking reconciliation state address the documented API limitations. Pass with residual remote race risk. |
| Local corruption | Invalid or unsupported state fails closed instead of silently creating an empty journal. Pass. |
| Privacy | No telemetry/backend; no request/response logging; exports omit token. See the privacy audit. Pass. |
| Dependencies | No downloaded Swift packages. CI action references are pinned to immutable commits and workflow permissions are read-only. Pass. |
| Testing | Unit, workflow, failure-injection, persistence, concurrency, duplicate, HTTP-contract, and recovery tests are present and pass. Pass. |

## Findings and dispositions

| Severity | Finding | Disposition |
| --- | --- | --- |
| Medium | The CI workflow previously referenced GitHub Actions by mutable major-version tags. | Remediated by pinning checkout and artifact upload actions to full commit hashes, disabling persisted Git credentials, minimizing permissions, and adding a timeout. Dependabot monitors action updates. |
| Medium | The ad-hoc local bundle is neither Developer ID signed nor notarized, and the app is not sandboxed. | Explicit public-binary release blocker. The source-build workflow remains appropriate for a private/local app; assess sandbox migration and data/Keychain continuity before distributing binaries. |
| Medium | A Personal Access Token workflow is owner-operated and unsuitable as delegated authorization for a broadly distributed integration. | Explicit public-binary/product release blocker. Implement and review YNAB OAuth and secret handling before offering a turnkey integration to other users. Do not add a shared token or client secret to the repository. |
| Low | Financial history is protected by filesystem modes but not application-level encryption. | Accepted for the documented local threat model; FileVault and protected backups are recommended. |
| Low | No client-side mechanism can atomically compare-and-set a category or assign multiple categories in one YNAB transaction. | Unavoidable API limitation. Baseline rereads, sequential writes, visible uncertainty, and user guidance reduce impact but cannot eliminate concurrent remote races. |
| Low | Restoring an old database weakens duplicate detection for later operations. | Residual backup risk is prominently documented; history is never presented as YNAB's source of truth. |

## Verification record

- `swift package show-dependencies`: no downloaded package dependencies.
- `swift build -Xswiftc -warnings-as-errors`: passed on Swift 6.2.3/macOS 15.6.
- `swift test`: 56 tests passed after repository-hardening changes.
- `swift test --sanitize=address`: the same 56 tests passed with Address Sanitizer enabled.
- Shell syntax check for packaging scripts: passed.
- App packaging, property-list validation, and strict deep code-signature verification: passed for the ad-hoc development bundle.
- GitHub workflow, issue-form, and Dependabot YAML parsing: passed.
- Repository secret-pattern scan: no live credential found; only credential-handling code, documentation, and synthetic test values matched.
- Tracked-artifact review: generated build/database/environment files are ignored; screenshots are synthetic.

## Release gates

Before public source publication, rerun CI and enable GitHub private vulnerability reporting once the repository is eligible. Before publishing a binary, additionally use a protected signing/notarization workflow, validate supported CPU architectures, decide and implement the correct YNAB authorization model, assess App Sandbox adoption and migration, produce checksums, and perform a clean-machine installation and network/privacy verification.
