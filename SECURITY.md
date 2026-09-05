# Security and financial correctness

## Supported versions

Payday is currently pre-release. Security fixes are provided on the latest commit of the `main` branch only. Once tagged releases begin, this table will identify the supported release line.

| Version | Supported |
| --- | --- |
| `main` | Yes |
| Older commits and untagged builds | No |

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's **Report a vulnerability** control on the repository's Security tab when private vulnerability reporting is available. While the repository is private, contact the repository owner privately through the contact information on their GitHub profile.

Include the affected commit or version, impact, reproduction steps using synthetic data, and any suggested mitigation. Never include a live token, budget export, database, account identifier, or personal financial screenshot. You should receive an acknowledgment within seven days. Timelines for validation and remediation depend on severity and reproducibility; no public disclosure should occur until a fix or mitigation is available.

If a YNAB token may have been exposed, revoke it immediately in YNAB Developer Settings and replace it in Payday.

## Security model

Payday is a local, single-user application with permission to change YNAB category assignments. Its intended trust boundary is your macOS account and login Keychain. It does not open a listening socket, install a service, collect telemetry, or receive remote commands.

Credentials belong only in Keychain. Do not put tokens, real budget exports, database files, account identifiers, or personal financial screenshots in issues or commits. The app intentionally omits request/response logs. Local history exports are sensitive.

The journal must be durable before a remote write. Never “fix” a stuck allocation by deleting history, resetting an in-flight step to pending, replaying the paycheck, or adding blind retry middleware. Financial uncertainty is a visible state requiring reconciliation. Tests covering loss of response, partial updates, local persistence failure, duplicate identity, concurrent confirmation, and final verification are release-critical.

SQLite contents are private by filesystem permissions but not application-encrypted. FileVault and appropriate backup protection are recommended. Malicious code running as the same user, a compromised OS, tampering with the data directory, and restoring old history are outside the app’s guarantees. The Keychain token is device-local and accessible only while unlocked; macOS controls access prompts.

YNAB does not offer category compare-and-set or a multi-category transaction. Live rereads reduce but cannot eliminate concurrent-edit races. A transaction ID also cannot establish that a human has never allocated the paycheck elsewhere. These limitations must remain visible in documentation and confirmation.

The latest structured assessment is in [docs/security-audit.md](docs/security-audit.md).
