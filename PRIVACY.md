# Privacy

Payday is a local macOS application. The project maintainer does not operate a Payday service and does not receive your credentials, budget data, usage, diagnostics, or history.

## Data the app handles

Payday receives the budget, month, category, currency, Ready to Assign, and optional income-transaction data needed for the workflow from YNAB. It stores your selected budget, category defaults, active draft, and allocation history locally. The YNAB Personal Access Token is stored separately in macOS Keychain and is not included in the database or history exports.

The history includes category names and identifiers, amounts, dates, references, operation status, assignment observations, and reconciliation notes. Optional JSON exports contain this financial information. Practice Mode uses a separate synthetic local data store and never reads the real token or contacts YNAB.

## Network activity

The app makes direct HTTPS requests to `api.ynab.com` only when you connect, refresh, inspect, or apply an allocation. It has no analytics, advertising, telemetry, crash-reporting service, update service, or maintainer-operated backend. A link to YNAB Developer Settings opens `app.ynab.com` in your browser only when you choose it.

GitHub and YNAB have their own privacy practices when you use their services. Do not put financial or identifying information in a GitHub issue or pull request.

## Storage and deletion

Real app data is stored under `~/Library/Application Support/Payday/`; Practice Mode data is under `~/Library/Application Support/Payday Practice/`. The enclosing folders and database are created with owner-only permissions. The contents are not application-encrypted and may be present in backups. FileVault and protected backups are recommended.

Disconnecting removes the token from Keychain but deliberately retains defaults and history. Revoke the token in YNAB Developer Settings to invalidate it at the source. To erase local data, quit Payday and delete the applicable Application Support folder; this also removes its duplicate-detection history. Delete any history exports separately. Removing history cannot undo an allocation in YNAB.

## Retention and control

Payday retains local configuration and history until you delete them. There is no remote copy for the maintainer to access, return, or delete. YNAB remains the source of truth for the budget and controls retention of data stored by YNAB.

The detailed data-flow assessment and residual risks are recorded in [docs/privacy-audit.md](docs/privacy-audit.md). Report a privacy or security concern using [SECURITY.md](SECURITY.md).
