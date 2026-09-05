# Open-source readiness audit

**Audited:** 2026-09-05

**Target:** private GitHub staging repository, ready for a later deliberate public-source decision

## Result

The repository has the expected foundation for an open-source project: a recognized permissive license, user and developer documentation, contribution and conduct policies, private vulnerability-reporting instructions, support boundaries, privacy and security assessments, synthetic examples, automated tests, reproducible local packaging, issue/PR templates, minimal-permission CI, and dependency update configuration.

It is appropriate to host privately and invite review. Public source publication should happen only after the owner reviews the repository history and enables the repository security settings listed below. A public downloadable binary is intentionally not represented as ready.

## Checklist

| Area | Status | Evidence |
| --- | --- | --- |
| Purpose and setup | Ready | `README.md` documents scope, requirements, workflow, safety, local data, and build steps. |
| License | Ready | MIT `LICENSE` with identified initial copyright holder and contributors. |
| Contribution governance | Ready | `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SUPPORT.md`, pull-request template, and structured issue forms. |
| Security reporting | Ready for private staging | `SECURITY.md`; enable GitHub private vulnerability reporting immediately before or when making the repository public. |
| Privacy transparency | Ready | `PRIVACY.md` and `docs/privacy-audit.md`. |
| Security assessment | Ready with binary-release gates | `docs/security-audit.md`. |
| Tests | Ready | Automated financial, persistence, recovery, concurrency, workflow, and HTTP-contract test suites. |
| CI and supply chain | Ready | Read-only workflow permissions, immutable action pins, warning-clean build, tests, packaging, short artifact retention, and Dependabot for actions. |
| Sensitive-data hygiene | Ready | Ignore rules, manual scan, synthetic fixtures/screenshots, and contributor warnings. |
| Change communication | Ready | `CHANGELOG.md`; begin tagged entries with the first release. |
| Architecture/API evidence | Ready | `docs/architecture.md`, `docs/verification.md`, and `docs/ynab-api-research.md`. |
| Public signed binary | Not ready by design | Requires signing/notarization, authorization decision, architecture validation, clean-machine verification, and release-specific threat review. |

## Repository settings

The staging repository should remain private, use `main` as its default branch, keep Issues enabled, disable the unused wiki and projects features, delete merged branches automatically, and avoid granting write permissions to Actions. Enable Dependabot alerts and private vulnerability reporting when the hosting plan/repository visibility supports them.

Before changing visibility to public:

1. Review every commit and staged artifact for personal information and secrets.
2. Run CI from a clean clone and inspect the produced development artifact.
3. Configure branch/ruleset protection appropriate to the number of maintainers.
4. Enable private vulnerability reporting and confirm the Security Policy link is visible.
5. Confirm repository description, topics, issue forms, license detection, and community profile.
6. Decide whether public publication is source-only; do not attach the ad-hoc CI artifact as a release.

## Maintenance cadence

Review dependency updates monthly, triage security reports promptly, keep supported versions accurate, update the changelog for user-visible changes, and repeat the privacy/security audits when trust boundaries change. Re-run the full release checklist for every distributed binary.
