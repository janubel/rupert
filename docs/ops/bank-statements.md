# Bank statements

Rupert has no connection to a bank account. **Finance → Bank statements** reads a statement CSV you download from your bank so a person can say what each withdrawal was.

1. Upload the CSV with an account *name* (never the account number). The original file is retained unchanged and encrypted as evidence (source `bank`, kind `bank_statement`).
2. Rupert reads the lines. It rejects a file it cannot read cleanly, with the line and reason, instead of guessing. If your bank shows withdrawals as positive numbers in one Amount column, tick the box on upload.
3. On the review page choose, per withdrawal: an expense category, a vendor payment, or ignore (transfer, deposit, personal). A category suggestion from keywords is shown but never applied for you. Deposits can only be ignored, because card deposits already arrive through the processor reports.
4. Saving records who decided and when, creates the expense or vendor payment (method bank transfer, reference to the statement line), and writes to the Activity log. A line is never imported twice, even if the same file or an overlapping month is uploaded again. If the date falls in an approved day or week, that approval shows as changed.

Books check lists bank lines still waiting. Lines are never deleted. This is manual import, not a bank reconciliation; a live feed (for example Plaid) could replace the upload later without changing the review step.
