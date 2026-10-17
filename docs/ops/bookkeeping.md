# Bookkeeping workspace

The Bookkeeping area opens `/bookkeeping`. The overview uses the latest imported month for the selected bank account by default. Choose a month and account explicitly to inspect history. Account-level bank movement is kept separate from workspace expenses and vendor payments; payouts never create a second sale.

- **Statement balance** appears only when retained bank evidence explicitly supplies an integer closing balance, currency and covered date, either directly on the transaction document or on a linked original. It is a historical statement balance, not a live account balance.
- **Money in / out / net movement** describes statement credits and debits, including transfers. These are cash movements, not revenue or profit. An unverified currency is shown as unverified rather than assumed.
- **Recorded expenses** includes active, confirmed expense records for the month. Pending bank lines and excluded transfers remain separate. Vendor payments are shown separately.
- **Needs your attention** opens pending bank lines. A clarification flag is independent of the financial decision: flagged lines remain pending and create no expense until a reviewer decides.

Bank review context uses `review_category`, encrypted `review_note`, `review_flag` and `reviewed_at`. The statement review page supports `show=flagged`, stable `bank-line-ID` anchors, category labels and question notes. The existing decision action records the expense or vendor payment, records the reviewer, clears the flag, and updates the review category. Source descriptions and retained originals stay intact.

The expense and vendor-payment registers accept `month=YYYY-MM`; expense CSV export preserves that month. Clearing the optional month restores the existing recent-day filter. Bookkeeping's shared navigation also carries the selected month between overview, expenses and vendor payments.

Daily source matching, close packages, approvals and period locks remain on **Close & review** (`/books`) and their existing pages. The overview does not certify reconciliation or lock a period. All routes retain their existing permission and tenant boundaries.

Real statements, transaction exports, review plans, receipts and production database copies must stay outside the public repository.
