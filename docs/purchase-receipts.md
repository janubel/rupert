# Purchase receipts

Open **Receipts** in the top navigation or the employee workspace. Finance also links to Receipts under Records. All active workspace users can upload and track their own receipts without access to business finance reports.

1. Upload a PDF, JPEG, PNG or WebP original (up to 10 MB), enter merchant, purchase date, total in USD, category and business purpose, and save the draft.
2. Check the original and details, then choose **Submit for approval**. Submission locks the details.
3. Another reviewer checks the original, confirms review, and chooses **Approve receipt** or **Return for correction**. Returning a receipt requires a comment.
4. The submitter can reopen a returned receipt, correct its details and resubmit. Previous reviews and the original file remain retained. A different original requires a new receipt.

Admins with `finance.write`, managers with `receipts.review`, and users explicitly granted `receipts.review` can review workspace receipts. Reviewers cannot approve or return their own receipts. Existing per-user and role permission overrides still apply; employees remain restricted to their own records and cannot receive business review powers through overrides. Account roles are not changed by this feature.

The review queue opens on submitted receipts. Filter by status to find drafts, approved or returned records. Non-reviewers only see their own records. Originals are downloaded through an authenticated workspace-scoped endpoint with attachment disposition and no caching. Signature-checked uploads, original checksums, encrypted file bodies and encrypted append-only event snapshots are retained in the application database, covered by the existing database backup process. Duplicate uploads of the same file by the same person are rejected; this does not detect every duplicate purchase, alternate scans or uploads by different people. Reviewers must check for those.

Review actions are version checked, serialized per workspace and recorded atomically with their audit event. Replaying an approval or using an old page cannot approve a different revision. Original files cannot be replaced or deleted through this workflow. The history records actors, decisions, comments and the purchase snapshot for each change.

Approval records a decision only. It does not create an expense, post a ledger entry or send reimbursement. Record accounting entries separately in the expense register after checking for existing entries. USD is the supported currency; other currencies need a separate accounting workflow. OCR, notification delivery and automated reimbursement are not implemented.

Deployment requires migration `20261017235700_create_purchase_receipts` on both supported adapters. Back up the database and preserve the encryption keys before promotion. The migration adds two tables and does not backfill or change existing business records.
