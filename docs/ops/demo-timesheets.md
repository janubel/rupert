# Demo timesheets for assigned review

Demo timesheets are fictional training records. Every list/detail and CSV identifies them as demo data; employee API responses include `demo`. Their marker cannot be cleared after creation. They are excluded from payroll generation and actual-hours summaries/reports even after approval. Importing real clock shifts into a demo is blocked.

An assigned employee reviewer can view and approve/return those demo sheets without receiving broad timesheet permissions or a role change. Existing management reviewers retain their normal permissions. Other employees cannot see them, and their owner cannot self-approve.

After verifying the production workspace and applying the additive migration, an account administrator can explicitly provision two previous full weeks:

```sh
bundle exec rails 'timesheets:demo[worker@example.com,workspace,reviewer@example.com,admin@example.com]'
```

The task requires existing active accounts and one linked worker. It creates 40-hour and 38-hour fictional weeks, ten labeled entries, an assignment, and submission audit events. Re-running preserves existing demo reviews; an occupied non-demo period or conflicting assignment aborts the whole transaction. It creates no pay rates, payslips, clock shifts, or provider transactions. Neither migrations nor sign-in provision demo data.

The additive migration is intentionally irreversible: removing the marker could turn fictional hours into payable records. Keep the exclusion code in every later release. Before any rollback to older code, remove the explicitly identified demo records under the deployment lock and verify that no demo hours remain.

Demo weeks also carry fictional credited sales and employee 50%-off card redemptions so the commission (1% of credited sales) and card bonus ($10 per redemption) display can be demonstrated. `TimesheetCompensation` derives the commission and bonus figures on read; they are display figures only and are never posted to payroll. Commission and card bonuses appear on the timesheet detail, list and CSV views.

## Commission and 50%-off card bonus demo

Demo weeks now also carry fictional credited sales and employee 50%-off card redemptions so the compensation display can be demonstrated. `TimesheetCompensation` derives a 1% commission on credited sales and a $10 bonus per card redemption on read; neither is posted to payroll. To demonstrate for sdolbec1@gmail.com, run the demo task with that account as the linked employee (and provide a distinct active reviewer and an account admin actor in the same workspace):

```sh
bundle exec rails 'timesheets:demo[sdolbec1@gmail.com,<workspace-subdomain>,<reviewer@example.com>,<admin@example.com>]'
```

The task output now prints `sales_cents`, `commission_cents`, `card_redemptions`, `card_bonus_cents` and `compensation_total_cents` per demo week, and the timesheet detail, list and CSV views show the same figures.
