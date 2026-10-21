# Sales-to-ledger posting: decision proposal (issue #204)

Status: **proposal, awaiting an owner decision.** Nothing here is enabled. Statements stay disclosed as incomplete (PR #211) until a choice below is recorded.

## What exists today

- `Finance::Posting.sale` journals one `Core::Payment` (the register payment): debit Cash, credit Revenue for the net amount, credit Sales Tax for the tax portion. It is idempotent per payment (`source_type`/`source_id`).
- Nothing calls it outside tests. Expenses and vendor payments already post in the same transaction as the record that causes them.
- It books every receipt to Cash. Card, Zelle and cash receipts are not distinguished, no processor fee or payout lag is modeled, and refunds are not posted.
- Imported sources (SwipeSimple transactions, Shopify orders, C-Trax sales) are separate from `Core::Payment` and are not posted at all.

## Decisions needed

1. **Authoritative sales source for the pilot.** Recommended: the register's `Core::Payment` only, because it is tenant-scoped, transactional and already has a duplicate-prevention identity. Imported processor data stays reconciliation evidence, not a posting source, until its identity and freshness are proven.
2. **Basis.** Recommended: cash basis recognized on the sale date, matching how expenses already post.
3. **Receiving account.** Recommended: replace "all receipts to Cash" with a clearing account (e.g. Undeposited Funds) debited at sale time. Deposits then move clearing to Checking when the bank statement line is matched, which uses the account-bound reconciliation from #203. Processor fees post to an expense account at payout.
4. **Refunds.** Recommended: a refund posts its own reversing entry (debit Revenue and Sales Tax, credit clearing) keyed by the refund identity, never by editing or voiding the original sale.
5. **Historical backfill.** Recommended: keep `backfill!` separate, add a dry-run that only reports counts and dates, require an operator to review it, and skip anything in an approved period.

## Alternative: do not post sales in the pilot

Keep the current disclosure, state in the pilot scope that income statement and balance sheet are not authoritative, and rely on the Daily Money and Books reports for sales. This is the lowest-risk option and needs no code. It is the default if no decision is recorded.

## Implementation outline if posting is chosen

- Hook posting into the register payment completion in the same transaction, tenant-scoped, with failure rolling the payment back (as expenses do).
- Refund posting path with its own idempotency key.
- Dry-run backfill command and operator review screen; no automatic historical posting.
- Tests: sale, tax split, refund, duplicate call, cross-tenant isolation, closed-period refusal, rollback on failure.
- Acceptance: reconcile one representative sale, refund and settlement against retained source evidence and record the accepted limitation.

## Out of scope

Inventory/COGS, multi-currency, per-item revenue accounts, and posting from imported processor data.
