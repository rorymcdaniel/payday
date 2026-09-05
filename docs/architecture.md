# Architecture

Payday is a Swift Package containing a native macOS executable with SwiftUI content and an explicit AppKit single-window lifecycle, a testable core library, and a system SQLite module. It has no downloaded runtime dependencies. Its process ends when the last window closes; only outbound YNAB requests require network access.

## Data ownership

YNAB owns the financial budget. Payday owns configuration, per-budget defaults, one active draft, and an append-only-in-purpose audit history (status/observations/notes are updated, but paycheck claims are never removed by the UI). Each history entry includes the original normal contributions, proposed adjustments, plan and currency, explicit month, intended before/after assignments, per-step state, and reconciliation notes.

The local SQLite database contains a versioned JSON document. This keeps this small personal app's schema inspectable and makes an entire transition transactional. `Store.update` copies the state, encodes it, commits an immediate SQLite transaction, and only then publishes the new in-memory state. SQLite uses rollback journaling and `synchronous=FULL`. It never overwrites corrupt history with defaults. A held `flock` on an adjacent lock file prevents another process from opening the same data store as a writer.

## Assignment protocol

1. Validate integer amounts, currency precision, selected plan, current month, nonnegative contributions, unique categories, exact total, and paycheck identity. Refresh currency metadata and optional linked deposit.
2. Read explicit month details, all month summaries, and category-group eligibility. Build a review with immutable before/target amounts; do not write anything.
3. On confirmation, reject a changed or expired draft. Revalidate deposit, currency, funds, and reviewed assignment baselines. Check available API request capacity.
4. Atomically reserve the paycheck and persist all category intents. Clear the draft in the same local transaction.
5. For each contribution, verify the remaining funds and all affected category assignments. Persist `sending`, send one absolute assignment PATCH, validate its response, and persist `verified`. No retry loop exists.
6. Read all affected categories and funds again. Only a complete final match becomes `completed`.

Any error after the paycheck claim becomes `needsAttention`. If a local commit itself fails, the previous durable `applying`/`sending` record remains a block. Relaunch converts interrupted operations to `needsAttention` and in-flight steps to `uncertain`. No automatic write is made on launch or inspection.

Manual reconciliation records a note and unlocks new paychecks, but neither changes the uncertain step statuses nor releases the paycheck identity. Observed equality does not prove causation; a delayed server write may still matter. This deliberately trades automatic recovery convenience for protection against duplicated or overwritten allocations.

## Concurrency and API limits

`AllocationEngine` is isolated to the main actor and holds a busy flag across suspension points during apply. The UI disables mutation while network work is in progress, and the store lock prevents a second process. Neither mechanism locks the user's other YNAB clients.

Snapshots combine three endpoints and are not atomic snapshots of the remote server. YNAB has no write precondition, so another client can change an assignment between the last read and PATCH. The confirmation explains that the user must avoid simultaneous edits. Future-month Ready to Assign is conservatively included in every snapshot's minimum.

A run uses roughly four requests per nonzero category after its last preflight snapshot. Rate-limit metadata is used to block starts that cannot fit. Other clients can consume quota concurrently, and missing headers make this estimate imperfect; an unexpected 429 still stops safely with an audit record. Very large allocations may need fewer categories to fit YNAB's 200-request hourly limit.

## UI and defaults

Money entry uses a native NSTextField field editor: digit entry shifts through the currency's minor units (cents for two-decimal currencies), formatting after every change and keeping the cursor at the end. Clicking selects the old amount. Invalid text stays visibly invalid and blocks review. Only valid integer milliunits persist.

Default changes and paycheck changes use distinct methods and store paths. `Draft.synchronizeDefaults` compares contributions with their previous baseline: untouched rows track new default amounts, overrides remain, omissions remain omitted, and new defaults populate immediately. Removed defaults are dropped if untouched, or retained as one-offs if adjusted. Default order is applied before one-off rows. The current draft's normal baseline advances with the defaults; committed history remains immutable with respect to later default changes.

Using Ready to Assign fetches a fresh conservative snapshot and fills the draft's amount, clearing any single-deposit link. It records the funding source and a dated reference, with a noncolliding suffix for additional RTA allocations that day. Reading it again in the same draft preserves identity. The normal durable claim, sufficient-funds checks, explicit confirmation, and uncertain-write recovery remain mandatory.

Practice mode constructs a local `DemoAPI` instead of a network client and never accesses Keychain. An optional `--demo-directory PATH` permits isolated UI verification; `--snapshot PATH` captures the app's own native view in practice mode without reading other windows or requiring screen recording.
