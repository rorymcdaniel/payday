# YNAB API integration research

Verified 2026-09-05 against YNAB's documentation and official SDK specification. No authenticated requests or real budget changes were made during this research. Recommendations below are engineering judgments, not guarantees made by YNAB.

## Current contract

The documented base is `https://api.ynab.com/v1`. The current changelog is v1.86.0. Since v1.79.0, `/plans/{plan_id}` and response keys `plans`/`plan` are primary; `/budgets/{budget_id}` remains compatible with its original response keys. Bearer personal access tokens suit owner-operated local applications, do not expire, and can be revoked. OAuth is required when obtaining delegated access for other users. Tokens require password-level care. The limit is 200 requests per token per rolling hour; 429 responses no longer include `X-Rate-Limit`. Dates use UTC. Monetary integers are thousandths of a currency unit. New decimal/formatted response fields do not remove integer fields. Transaction listings default to one year; use an explicit date range. [Official API documentation and changelog](https://api.ynab.com/)

Recommendation: keep the token in macOS Keychain, select and persist an explicit plan ID, pin the reviewed month to `YYYY-MM-01`, and perform all arithmetic in checked integer milliunits. Never choose the write target through `last-used` or `current` aliases.

## Contributions, not balances

`PATCH /plans/{plan_id}/months/{month}/categories/{category_id}` accepts `{"category":{"budgeted":123000}}`. It updates the month's absolute Assigned amount, not Available and not an increment. Only `budgeted` can be changed at this endpoint. Month detail supplies all month-specific categories; category listing amounts otherwise refer to the current UTC month. [Official endpoint reference](https://api.ynab.com/v1)

Thus the correct write is:

```text
targetAssigned = freshlyReadAssigned + paycheckContribution
```

If a category has Assigned 500, Activity −465 and Available 35, contributing 400 means setting Assigned to 900. Available becomes 435 if nothing else changes. Existing rollover and spending never reduce the intended contribution. Do not create transactions or edit targets to implement assigning.

## Ready to Assign and future months

`MonthSummary.to_be_budgeted` is Ready to Assign, and the month listing returns summaries. `budgeted` is Assigned, `balance` is Available. The schema exposes `internal`, `hidden`, and `deleted` for categories. [Official OpenAPI specification](https://raw.githubusercontent.com/ynab/ynab-sdk-python/main/open_api_spec.yaml)

When assigning ahead, YNAB says the future-most month's Ready to Assign is the most up-to-date. The current month can show zero while a future month is overassigned. Additional income covers current/future overassigning first. Cash overspending reduces the following month's Ready to Assign. [YNAB: negative Ready to Assign](https://support.ynab.com/en_us/when-ready-to-assign-is-negative-an-overview-HylZA0zCc)

Recommended conservative guard: fetch complete month summaries, require the selected month to exist, and use the minimum Ready to Assign from the selected month through all later returned months. Compare it with the entire remaining contribution total before each write; reject a negative/insufficient result. Include current month too if later-month allocation is supported. Re-read after completion. This deliberately may block some unusual budgets; it avoids treating a positive current amount as proof that future money is free. No local check can reserve funds against simultaneous edits by another YNAB client.

## Atomicity, retries, and honest recovery

The inspected specification documents one-category assignment PATCH only. It documents no bulk category assignment, conditional revision/`If-Match`, category idempotency key, or multi-request transaction. `server_knowledge` supports delta reads, not a write precondition. These are absences from the public contract, not claims about server internals. [Official OpenAPI specification](https://raw.githubusercontent.com/ynab/ynab-sdk-python/main/open_api_spec.yaml)

Engineering consequences:

1. Persist an operation UUID, paycheck identity, immutable contributions/default snapshot, and each category's before/target values before sending any mutation. Serialize writers across windows/processes.
2. Persist a row as in-flight before sending its PATCH. Send sequentially and record confirmed replies durably. Recheck fresh category assignments and funds immediately before proceeding.
3. On timeout, connection loss, malformed success, interrupted launch, or persistence failure, stop. Clearly distinguish confirmed, uncertain, and never-attempted rows. Do not automatically replay the paycheck, recompute an uncertain target from its current value, or roll back successful rows.
4. Recovery may read observed assignments. A match with a saved target is useful evidence but cannot prove which client made the change; a match with the original value cannot prove a delayed request will never arrive. Keep unresolved outcomes visible and require deliberate reconciliation before new writes.
5. A final read must verify every target before reporting verified completion. Concurrent external edits can still race a read/PATCH pair; ask users to avoid editing YNAB while applying and state this limitation honestly.

YNAB now has money-movement/group read endpoints, including month-scoped reads, but no documented write endpoint for these resources. They may aid manual investigation; they do not provide a client-generated idempotency key. [Official money-movement API](https://raw.githubusercontent.com/ynab/ynab-sdk-python/main/docs/MoneyMovementsApi.md)

## Identifying a paycheck

Transaction reads exclude pending transactions and support `since_date`; individual transactions can be fetched again by ID. The separate transaction-creation API supports duplicate `import_id` detection, which does not apply to category assignment. [Official transactions API](https://raw.githubusercontent.com/ynab/ynab-sdk-python/main/docs/TransactionsApi.md)

Transaction details include ID, amount/date, account/category, deleted state, transfer identifiers, matched transaction ID, import ID, and split subtransactions. Import IDs are unique by account. [Official transaction model](https://raw.githubusercontent.com/ynab/ynab-sdk-python/main/docs/TransactionDetail.md)

Recommendation: associate a paycheck with an existing positive income transaction when available; reject deleted, transfer, split, future, and non-budget-account candidates unless explicitly supported. Persist `(planID, transactionID)` as a unique claim and consider matched/import identities as additional duplicate evidence. Revalidate before applying. A user-entered date/amount/reference fingerprint is weaker and should be described as such: two equal deposits may be legitimate, and a user can rename a reference. Never claim the app can detect allocations performed outside its history or after its local history has been erased.

## Currency and category eligibility

The plan currency format includes ISO code, decimal digits/separator, grouping separator, and symbol placement; it can be null. [Official currency model](https://raw.githubusercontent.com/ynab/ynab-sdk-python/main/docs/CurrencyFormat.md)

Recommendation: require a known supported format for writes, parse exact decimal text with overflow checks, and enforce its precision (including zero- and three-decimal currencies). Exclude hidden, deleted, and internal categories and invalid groups without hard-coded English names. Treat a removed/hidden default category as a visible validation error, never silently drop its contribution. Save one-off changes into future defaults only through an explicit action.

### Eligibility uncertainty: credit-card payment categories

The `internal` exclusion above is a conservative policy, not a verified guarantee that all valid payment categories remain available. The official [category](https://raw.githubusercontent.com/ynab/ynab-sdk-js/main/src/models/Category.ts) and [category-group](https://raw.githubusercontent.com/ynab/ynab-sdk-js/main/src/models/CategoryGroup.ts) models describe `internal` but do not state its value for credit-card payment categories or their group. The generated endpoint examples use placeholder names and all-true booleans; they are not real-budget evidence. Neither the category model nor the [account model](https://raw.githubusercontent.com/ynab/ynab-sdk-js/main/src/models/Account.ts) exposes an explicit account/payment-category linkage.

Payment categories are valid destinations for direct assignments; YNAB recommends assigning cash to them for payments. [YNAB credit-to-cash guidance](https://support.ynab.com/en_us/the-credit-to-cash-roadmap-r11FgcqJx?mobile-help=true) Their precise `internal` flags need a read-only check on a consenting owner's budget or clarification from YNAB before claiming full payment-category compatibility. Do not infer those flags from the fact that YNAB creates the categories automatically, or relax filtering based only on a category's name.

### Publication and personal tokens

Owner-built local use of the owner's own PAT fits the documented personal-use scenario. The documentation also reserves obtaining tokens for other users to OAuth and does not provide an explicit exception for distributing source code or locally running third-party binaries. Therefore, describe this release as owner-operated personal use; do not present PAT entry as a verified general-public authorization strategy. Before distributing a polished application to other users, use OAuth or get YNAB's clarification about the exact owner-built source-distribution model. This is a reading of the documentation, not a legal conclusion. [YNAB authentication documentation](https://api.ynab.com/#authentication)
