# Sales, stock, finance and reconciliation workspace

Sales, stock comparison, physical counts, catalog links and finance/evidence
screens share role-filtered workspace navigation and keyboard-scrollable tables.
Company modules retain their existing server permissions. Cashiers and inventory
staff use their existing module access; self-service employees remain limited to
POS and personal time records. Optional help stays collapsed on these task pages.

Sales summaries and charts use the same recorded USD sales definition as the
dashboard: paid/fulfilled canonical orders and native completed C-Trax orders
once, excluding payment/deposit mirrors. Charts end on the selected date.
The paginated canonical journal retains per-order currencies and status filters;
native C-Trax receipts remain in daily close. Source pull timestamps and native
business-date coverage remain distinct. Hourly detail covers all 24 local hours.

Stock comparison exposes source freshness, signed/unknown values, scoped search,
and a direct jump to results. C-Trax remains the physical retail reference.
Catalog Links is a separate read-only identity audit with search/status filters;
size changes are reviewed in their dedicated workspace. These screens do not
write stock or SKUs to any provider.

Finance overview separates received balances, credits/prepayments, purchase
commitments and customer/currency receivables. Missing order amounts keep the
corresponding receivable unknown. Vendor payments without purchase orders remain
visible as credits. Fresh local balances are queried after edits. The ledger
mirror groups currencies separately and is never additional revenue.

Expense, vendor-payment and account-code forms use the controller's expected
field scopes. Dollar input is parsed exactly through a model concern; blanks,
negative values, exponents, fractional cents and values beyond the existing
32-bit cents column range are rejected. Invalid input stays on the form.
Expense/payment lists paginate, count the complete selected period and exclude
removed history from active totals. CSV can include removed history with an
explicit State column. Recording a payment updates local records only.

Financial close presents current review, checks, originals and follow-ups above
a three-step evidence/compare/retain path. Blockers and the close checklist sit
beside each other on wide screens and stack on phones. Daily checks, original
search, follow-up progress, cash planning and period evidence share date context.
Period observations are grouped by source without a combined money total.
Existing fingerprint, checksum, optimistic-lock, stale-form, replay and close
requirements remain authoritative. No automatic bank matching, source writes,
messages or ledger posting were added.
