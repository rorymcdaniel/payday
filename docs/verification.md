# Verification

Local verification on 2026-09-05: macOS 15.6, Apple Silicon, Swift 6.2.3 / Xcode SDK 26.2. The packaged executable targets macOS 15.0 and later. No real YNAB credentials, authenticated budget reads, or financial writes were used.

## Automated checks

`swift build -Xswiftc -warnings-as-errors`: passes.

`swift test`: 56 tests pass. The same 56 tests pass under Address Sanitizer with `swift test --sanitize=address`.

Coverage includes:

- Exact milliunit arithmetic; variable paycheck difference; zero- and three-decimal currencies; invalid, negative, subprecision, and overflowing input.
- Contributions added to Assigned, preserving Available rollover and spending effects. Existing $35 + $400 becomes $435; existing $2,000 + $75 becomes $2,075.
- Exact-total, month-rollover, category eligibility, currency precision, changed-draft, stale assignment, linked-deposit, and Ready to Assign validation.
- Duplicate confirmation, a new UUID with the same manual paycheck identity, renamed linked deposits, matched transaction aliases, and simultaneous confirmation while the first request is suspended.
- Server commit followed by connection loss, second-write failure, funds changes midway, external category edits, final read failure, and conflicting final assignments.
- Durable in-flight intent before each write; local disk permission failures before and after a remote write; exclusive instance locking; crash recovery; persisted history/defaults; omitted default contributions remaining auditable.
- Conservative future-month funds checks, required currency metadata, path validation, exact HTTP PATCH body, failure without retries or leaked response data, and rate-limit preflight. HTTP tests use `URLProtocol`, with no network.

## Native workflow checks

Version 1.1 adds tests for automatic population of empty drafts, default amount synchronization, preserved paycheck overrides and omissions, persisted category ordering, cents-first typing/backspace through the native field coordinator, explicit default reset, and Ready to Assign allocations followed by new income on the same day. The updated native layout is captured in [the v1.1 screenshot](screenshots/paycheck-v1.1.png). Tests use isolated stores and fake/local APIs and do not access the real Keychain or budget.

Used the actual packaged app in practice mode, with synthetic local data:

- Started at paycheck $4,123.72, defaults $4,075.00, remainder $48.72.
- Changed a contribution through a native text field; the allocated/overallocated totals updated and review was disabled while overallocated.
- Used the remainder menu to finish the allocation exactly.
- Opened the review sheet and verified that it showed all eight contributions, the explicit budget/month, $435 projected Groceries availability, and confirmation acknowledgement.
- Confirmed into the practice API. SQLite recorded `completed`; Dining's history contribution was 148720 milliunits while its future default remained 100000.
- Closed the native window and verified process termination; reopened the app and checked that completed history persisted and a fresh draft started with the normal contribution.
- Balanced the new draft under the same paycheck identity and attempted review. The native app displayed “This paycheck already has an allocation in History. It cannot be applied again.” History remained at one completed operation.
- Rendered the actual native content view to [a screenshot](screenshots/paycheck.png). Corrected a flexible table-header spacer discovered during visual inspection.

Practice data can be isolated without touching normal practice history:

```sh
payday_test_dir="$(mktemp -d)"
open dist/Payday.app --args --demo --demo-directory "$payday_test_dir"
```

The optional practice-only `--snapshot /absolute/output.png` captures the app's own content view after launch. It needs no Screen Recording permission and does not capture other applications. Accessibility automation, if used for native interaction, is a separate macOS permission.

## Packaging

`bash scripts/package.sh` produces `dist/Payday.app`, including a code-drawn icon, valid Info.plist, and an ad-hoc signature. `codesign --verify --deep --strict` and `plutil -lint` pass. `vtool -show-build` reports a macOS 15 minimum deployment target.

## Remaining external validation

Before relying on the app with a real budget, its owner must connect their own token and verify the selected budget/category list and review. No live YNAB write smoke test was performed. In particular, credit-card payment category internal flags and Keychain access prompts across separately signed builds were not exercised with personal credentials. General binary distribution requires additional signing/notarization and YNAB authorization-policy work described in the README.

The API offers no atomic assignment or compare-and-set primitive. No passing local test can establish safety against simultaneous changes in a separate YNAB client; the app's confirmation and documentation state this limit.
