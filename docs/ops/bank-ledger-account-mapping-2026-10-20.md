# Statement accounts and ledger coverage — October 20, 2026

Implementation follow-up to [deployment gate #203](https://github.com/techmore/rupert/issues/203) and the remaining M1/M7 findings in #169. This is a code/test checkpoint, not a production deployment or operator acceptance receipt.

## Explicit account mapping

Bank reconciliation requires a finance editor to map a statement label to one active asset account in the current workspace. The mapping is saved and audited. Each ledger account has one statement label; aliases cannot count the same account twice. Existing labels stay unmapped until reviewed. Their bank evidence remains visible, but ledger net/difference and matching remain unavailable rather than mixing Cash and Checking.

Suggestions, existing confirmed links, unmatched ledger movements and totals use the selected account only, within the displayed dates. Multiple legs in that account are aggregated into one signed movement per journal entry. An entry can reconcile once per statement account, allowing the two sides of a transfer to match their respective statements while duplicate matching within one account is rejected by validation and a database unique index. A zero net difference does not establish complete records or opening/closing bank balance reconciliation.

Initial mappings must agree with existing journal links. A mapping with links cannot be changed silently; recorded-source history is preserved and must be reviewed separately. Mapping and statement source decisions serialize per workspace, while manual matching locks the mapping, statement line and current journal entry. A stale object cannot match an entry that has since been voided.

Statement expense/vendor-payment creation still posts to Checking (1100). If the label maps elsewhere, that action is refused before creating financial records. A finance editor can instead create the correctly reviewed journal entry and confirm it in reconciliation. This change does not introduce automatic recoding, backfill, or a new source-posting policy.

## Financial report coverage

For [gate #204](https://github.com/techmore/rupert/issues/204), the financial report index, trial balance, income statement, balance sheet and statement CSVs now disclose incomplete automated sales/settlement/refund posting. They describe posted ledger entries only. Balance is not proof of complete business accounts. No sales posting or historical backfill was enabled; the accounting-source, settlement, refund and acceptance decisions remain open.

## Migration and rollout

Migration `20261020140000` creates the tenant-scoped mapping table and changes the bank-line uniqueness key from journal entry alone to workspace/statement label/journal entry. It does not assign mappings or rewrite historical statement lines, journal entries, approvals or source records. Both PostgreSQL and SQLite schemas are retained.

Take and verify the normal private recovery point before rollout. Before any rollback, preserve the new mapping configuration. Down/up is supported while old global entry uniqueness still holds. If an entry has valid matches across multiple bank accounts, rollback refuses before changing schema rather than deleting matches; keep a compatible application or arrange an operator-reviewed recovery plan. Never restore an older business database over newer writes.

Tests cover unmapped history, cash/checking/custom account separation, ignored lines, compound entries and transfers, cross-workspace and permission rejection, duplicate/index protection, preserved history, stale voided entries, custom-account source-posting refusal, report disclosures and migration rollback/reapply. The representative real statement review remains open. No production database, source platform, merchant payment or live deployment was touched.
