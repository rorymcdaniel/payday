## What changed

Describe the user-visible outcome and why it belongs in Payday's focused scope.

## Safety impact

Explain any effect on YNAB writes, money arithmetic, duplicate protection, failure ambiguity, credentials, privacy, persistence, or release behavior. Write “None” only after checking each area.

## Verification

- [ ] `swift build -Xswiftc -warnings-as-errors`
- [ ] `swift test`
- [ ] `bash scripts/package.sh`
- [ ] UI changes checked in Practice Mode
- [ ] Failure paths tested when persistence, networking, concurrency, or remote writes changed
- [ ] Documentation and audit records updated where applicable
- [ ] All fixtures, logs, exports, and screenshots are synthetic and contain no secrets or personal data

## Notes for reviewers

Call out remaining uncertainty, manual checks, or follow-up work.
