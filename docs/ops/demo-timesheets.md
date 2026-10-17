# Demo timesheets for assigned review

Demo timesheets are fictional training records. Every list/detail and CSV identifies them as demo data; employee API responses include `demo`. Their marker cannot be cleared after creation. They are excluded from payroll generation and actual-hours summaries/reports even after approval. Importing real clock shifts into a demo is blocked.

An assigned employee reviewer can view and approve/return those demo sheets without receiving broad timesheet permissions or a role change. Existing management reviewers retain their normal permissions. Other employees cannot see them, and their owner cannot self-approve.

After verifying the production workspace and applying the additive migration, an account administrator can explicitly provision two previous full weeks:

```sh
bundle exec rails 'timesheets:demo[worker@example.com,workspace,reviewer@example.com,admin@example.com]'
```

The task requires existing active accounts and one linked worker. It creates 40-hour and 38-hour fictional weeks, ten labeled entries, an assignment, and submission audit events. Re-running preserves existing demo reviews; an occupied non-demo period or conflicting assignment aborts the whole transaction. It creates no pay rates, payslips, clock shifts, or provider transactions. Neither migrations nor sign-in provision demo data.

The additive migration is intentionally irreversible: removing the marker could turn fictional hours into payable records. Keep the exclusion code in every later release. Before any rollback to older code, remove the explicitly identified demo records under the deployment lock and verify that no demo hours remain.
