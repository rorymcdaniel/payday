# Contributing to Payday

Thank you for helping make paycheck allocation safer and easier. Payday is intentionally narrow: it adds one paycheck's contributions to existing YNAB category assignments. Proposals that preserve that focus are especially welcome.

## Before you begin

- Read [SECURITY.md](SECURITY.md), [PRIVACY.md](PRIVACY.md), and the [architecture notes](docs/architecture.md).
- Use an issue to discuss substantial behavior or architecture changes before investing in an implementation.
- Report vulnerabilities privately. Never put a live token, real budget data, database, history export, account identifier, or personal financial screenshot in an issue, pull request, fixture, or commit.
- Use Practice Mode and synthetic data for development. Tests must never contact YNAB or read Keychain credentials.

By contributing, you agree that your contribution is licensed under the repository's [MIT License](LICENSE) and that you have the right to submit it.

## Development setup

Payday requires macOS 15 or later and a Swift 6 toolchain from Xcode or Apple Command Line Tools. It has no downloaded package dependencies.

```sh
swift run Payday --demo
swift build -Xswiftc -warnings-as-errors
swift test
bash scripts/package.sh
```

The packaged development app is written to `dist/Payday.app`. Generated data, build output, database files, and local environment files are ignored by Git; verify that no sensitive artifact is staged anyway.

## Correctness rules

Changes to the allocation engine must preserve these invariants:

- Contributions increase the month's existing Assigned values; they do not set Available balances.
- The proposed contributions must exactly equal the amount being allocated.
- Sufficient Ready to Assign and unchanged assignment baselines are checked before writes.
- The immutable local claim and write intent are durable before the first remote write.
- A request with an ambiguous response is never retried automatically or represented as successful.
- Partial or uncertain operations remain visible and block another apply until reconciled.
- Defaults change only through an explicit defaults action; paycheck edits are temporary otherwise.
- Every financial amount uses integer milliunits rather than floating-point arithmetic.

Add or update tests for every behavior change. Failure-path tests are required for changes involving persistence, concurrency, networking, or remote writes. API claims should cite current official YNAB documentation.

## Pull requests

Keep pull requests focused and explain the user-visible effect. Before requesting review:

1. Run the build, test, and packaging commands above.
2. Confirm new fixtures and screenshots are synthetic and contain no metadata or identifiers from a real budget.
3. Update user documentation and audit records when trust boundaries, stored data, networking, or release behavior changes.
4. Describe manual verification, including Practice Mode checks for UI changes.
5. Call out any remaining ambiguity or behavior that could affect a real budget.

Code should favor explicit domain names, small testable seams, and fail-closed behavior over convenience. Avoid adding dependencies unless their value clearly exceeds their privacy and supply-chain cost.
