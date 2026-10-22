# Sales-to-ledger posting decision — issue #204

**Status: the owner decision is recorded and the implementation is merged.** This page's original proposal is superseded; its former "awaiting an owner decision" status and recommendation list no longer describe `main`.

The current decision and implementation record is [Sales-to-ledger posting plan](../finance-ledger-posting-plan.md). It defines the authoritative source, cash-basis recognition, tender/clearing accounts, refund handling, idempotency, failure behavior, and guarded dry-run/backfill rules. Implementation merged in [PR #283](https://github.com/techmore/rupert/pull/283).

## Remaining acceptance for #204

- Review the production dry-run tables before any historical backfill or card reclassification. Posting requires both `CONFIRM=1` and an explicit `TENANT_ID`.
- Reconcile a representative sale, refund, and processor settlement against retained source evidence and record the accepted limitation.
- Keep incomplete coverage visible: processor deposits and fees are not automatically matched to clear account 1150; gift-card and store-credit refunds remain unposted until a liability account is defined.

This page update does not run a task, change financial records, or claim production acceptance. Keep issue #204 open until the remaining evidence is recorded.
