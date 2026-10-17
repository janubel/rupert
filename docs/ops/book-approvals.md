# Approve books

`/approve_books` (Money → Approve books) is the sit-down-with-coffee screen.

1. Pick **Daily** or **Weekly** (weeks run Monday to Sunday). The strip of the last 14 days shows what is approved, approved with exceptions, flagged, or not yet approved.
2. Read **Money in** (each source and currency on its own line, never added together; "Unavailable" is not zero), **Money out**, and **What to look at**. Each flagged day links to its close page.
3. Choose a decision, add a note if it is not a plain approval, tick that you looked, and record it. Open checks block a plain approval; use "Approve with exceptions" and explain.

The record holds your name, user id, UTC time, network address, browser, the frozen numbers you saw, and a fingerprint of the evidence. Each entry's fingerprint includes the previous entry's, so editing, removing or reordering an entry is detected and shown on the page and in **Books check**. If sales, payments, controls, originals or money-out records change later, the approval reads **Changed since approval** until someone looks again. Editing an expense or vendor payment inside an approved day warns the editor and writes `edit_in_approved_period` to the Activity log.

Viewing needs `reports.read`; deciding needs `reports.write`. Only finished days and weeks can be approved. Approvals are not a bank reconciliation or tax filing, and they do not lock records.
