# Privacy audit

**Audited:** 2026-09-05

**Scope:** application source, persistence, Keychain integration, network client, packaging, tests, screenshots, and repository contents

## Executive result

No telemetry, advertising, analytics, maintainer backend, remote logging, embedded third-party SDK, or downloaded Swift dependency was found. Production network access is limited to the YNAB API, plus a user-initiated browser link to YNAB Developer Settings. Credentials are stored in macOS Keychain rather than the application database.

Payday necessarily handles sensitive financial metadata. Its local database and user-created exports are not application-encrypted. This is documented and proportionate to the stated single-user, local-only threat model when the Mac account, FileVault, and backups are protected. No real credentials or recognizable personal financial data were found in the source tree; repository screenshots use synthetic data.

## Data inventory

| Data | Source | Location | Purpose | Retention |
| --- | --- | --- | --- | --- |
| YNAB Personal Access Token | User | macOS Keychain, service `app.payday.ynab` | Authenticate direct YNAB requests | Until Disconnect, Keychain deletion, or app reset |
| Budget name and ID | YNAB/user selection | Local SQLite document | Select and identify the target budget | Until local data deletion |
| Category names and IDs | YNAB | Local defaults, drafts, and history | Configure and audit allocations | Until changed or local data deletion |
| Contribution amounts, paycheck amount, date, reference, and month | User/YNAB | Local draft and history | Prepare, deduplicate, and explain allocations | Draft until replaced; history until local data deletion |
| Optional deposit transaction ID and import aliases | YNAB | Local draft/history | Link and deduplicate a specific deposit | Until local data deletion |
| Assignment baselines, targets, responses, and operation state | YNAB/app | Local history | Detect races, partial writes, and uncertainty | Until local data deletion |
| Reconciliation observations and note | YNAB/user | Local history | Resolve an interrupted operation safely | Until local data deletion |
| Practice Mode state | Synthetic/app | Separate Practice Mode directory | Development and safe evaluation | Until deleted |
| History export | User action | User-selected JSON file | Portable audit record | Controlled by user |

The app does not need or request bank credentials, account balances, spending transactions beyond an optional income match, contacts, location, camera, microphone, screen recording, or accessibility access.

## Data flows

1. The user enters a token; Security framework stores it in the login Keychain with `WhenUnlockedThisDeviceOnly` accessibility.
2. The app retrieves that token in memory to send bearer-authenticated HTTPS requests directly to `https://api.ynab.com/v1`.
3. Responses needed for the current workflow are rendered and selected fields are committed to the owner-only local database.
4. Applying writes absolute category Assigned values to YNAB; the durable local journal records intent and evidence before and after each request.
5. A history export writes selected local history to a location chosen through the macOS save panel. The token is never included.

An ephemeral URL session disables cookies and URL caching. The application does not log request headers, response bodies, or tokens and refuses HTTP redirects for production YNAB requests.

## Repository and development review

- No package dependencies are declared beyond system SQLite.
- Source/test fixtures use synthetic identifiers and a fake `test-token` only.
- The checked screenshots contain synthetic category names and amounts and no embedded author, location, or provenance metadata was detected.
- Build products, databases, environment files, and macOS metadata are excluded by `.gitignore`.
- CI tests and packaging do not access secrets or real YNAB data.
- Contribution templates explicitly prohibit submitting credentials or real financial artifacts.

## Findings and dispositions

| Severity | Finding | Disposition |
| --- | --- | --- |
| Medium | The repository lacked an explicit privacy policy and durable data inventory. | Remediated by `PRIVACY.md` and this audit. |
| Low | Local history and optional exports contain financial metadata without app-level encryption. | Accepted for the local single-user model; owner-only modes, FileVault guidance, export warnings, and deletion instructions are documented. |
| Low | Disconnecting removes the credential but retains financial history, which may surprise users. | Retention is intentional for audit safety and is now stated explicitly with complete deletion instructions. |
| Low | Backups may retain the database or exported history after local deletion. | Residual platform/user risk; protected backups are recommended. |
| Informational | Opening issues or pull requests moves submitted content to GitHub. | Templates and policies require synthetic data and direct security reports to a private channel. |

## Re-audit triggers

Repeat this review before adding telemetry, crash reporting, automatic updates, cloud sync, a new network host, a third-party dependency, OAuth, new macOS permissions, new exported fields, or a distributed binary. Update this document whenever stored fields or retention behavior changes.
