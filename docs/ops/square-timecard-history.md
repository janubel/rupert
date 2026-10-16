# Square timecard history

Square history is read through `POST /v2/labor/timecards/search` with `TIMECARDS_READ`. No Square create, update or delete endpoint is used. The complete paginated read must finish before the tenant-serialized publication. A changed connection, duplicate source ID, pagination cycle or partial response prevents publication.

Run `TENANT_ID=... ACTOR_ID=... bundle exec rails square:timecards` to inspect matches without writes. Add `APPLY=1` to import locally. The actor must be an active account administrator with timesheet-write access in the tenant. This is an operator-initiated import, not a recurring job.

Native timecard IDs are unique per tenant. Team-member IDs resolve only through retained Square employee source identities, including consolidated profiles. Names and email addresses are never used to guess identity. Inactive historical employees can receive history without activation, accounts or invitations.

Timecards and exact paid seconds per source-local date are retained in separate tables. Unpaid breaks are subtracted, paid breaks retained, and midnight/DST boundaries use the source IANA timezone. Zero-duration closed records remain visible with zero hours. Personal reports/calendar include each imported day once; source hourly wages provide basic estimates without changing employee pay-rate settings or inventing overtime, deductions, approvals or payment status. These historical records never enter new Rupert payroll generation.

Open, unmatched, invalid or overlapping records contribute no additional hours. Potential overlap with local manual daily hours is held conservatively; precise non-overlapping Rupert clock shifts may coexist. Local clock/entry writes share the importer’s tenant lock and reject overlapping imported history. Further employee consolidation moves source history and checks for overlap first.

A source correction, reassignment or disappearance retains the original imported hours and is flagged for review. Refreshes do not overwrite or delete historical days, infer payroll payment, or duplicate records. Original/latest source payloads are encrypted at rest and are not returned by the employee API.

Web history at `/people/square_timesheets` is employee-scoped, with broader review only for account administrators with timesheet-read access. The GET-only employee API at `/api/v1/employee/square_timecards` always forces its authenticated employee, including for native administrator sessions. CSV exports follow the same boundary and escape spreadsheet formulas. Preview mode remains synthetic.
