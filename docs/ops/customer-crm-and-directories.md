# Customer CRM and employee directories

Open **Sell → Customer CRM** (`/customers`) for contact search, source and relationship filters, tags, assignment, overdue follow-ups, local profile summaries, an attributed conversation history, and a filtered contact CSV export. Follow-ups can be completed or reopened. Emails recorded in the history are logs of past contact; this feature does not send messages.

Manual contacts have editable contact details. Imported contact details are maintained by their source; Rupert display names, tags, relationship status, assignment, notes, interactions and follow-ups survive refreshes. Native profiles are separate: a shared name, email or phone number is not evidence of identity. Order history is paginated and amounts remain separated by native currency. A native profile count is not a count of unique people.

Open **People → Employees** (`/people/employees`) for the paginated roster, source filters and login readiness. Open an employee, confirm identity and employment details, then use **Create private setup / reset link** to issue the existing one-time, 24-hour web setup link. Employee logins start at `/employee`. Syncing staff does not provision accounts, grant roles, assign wages or terminate employees. Review matching staff profiles across apps before provisioning an employee's primary HR record.

## Coverage and access

The source coverage panel distinguishes last successful full reads, failures, missing configuration and paused schedules. Read-only refresh buttons require the directory's write permission plus `sync.write`. Scheduled directory jobs run every 30 minutes for active tenants; C-Trax respects its hourly-sync switch and SwipeSimple respects automatic reporting being enabled. Each tenant's settings cache is refreshed before scheduled reads.

| Source | Customers | Employees | Requirements / limits |
| --- | --- | --- | --- |
| C-Trax | Complete native paginated customers | Native store users across accessible stores, excluding platform superusers | Authorized connection; preserves native IDs scoped to source host |
| Shopify | Complete paginated customers | Complete paginated staff when entitled | Customers require `read_customers`; staff requires `read_users`, an eligible plan and Shopify approval |
| Square | Complete paginated public-contact profiles, checked against native count | Complete team search, including inactive team members | Saved tenant token with `CUSTOMERS_READ` / `EMPLOYEES_READ`; no fallback to platform-wide credentials |
| SwipeSimple | Complete native customer grid | Complete native company user grid | Authorized saved website login and matching company; fresh ephemeral sessions; account status is not supplied by the user grid |
| IRIS | No directory | No directory | Merchant/bank reporting only |

SwipeSimple Appointments has an independent customer directory. Its contacts are not covered by the standard SwipeSimple customer grid. This release does not claim Appointments coverage. Other unconfigured/evaluation providers are not represented as synced.

Every reader validates pagination, native identities, counts where supplied, and a complete terminal page before publishing atomically. An incomplete response, changed credentials, duplicate IDs, access failure or changed company retains prior data. Native employee absence marks source availability only; local HR status and login associations are preserved. A failed Shopify staff read is never represented as a successful zero-person roster. SwipeSimple login/verification errors pause automatic website attempts until setup is corrected.

## Security and deployment

CRM reads use `customers.read`; mutations and CSV export use `customers.write`. Related records and assignment references must belong to the active tenant. Foreign nested IDs return 404. Contacts, notes and task form bodies are filtered from request logs. CSV export requires narrower filters over 25,000 profiles and neutralizes leading spreadsheet formulas. No upstream business writes are performed.

The additive `20261016041000` migration adds CRM fields to existing profiles plus attributed interaction and follow-up tables. Retain consistent database/environment backups and the current SER8 release, use `/var/lock/rupert-deploy.lock`, rehearse migration and authenticated pages on a private database copy, and check the exact production revision before promotion. Native iPhone/Android signing and distribution remain deferred.

## Provider references

- [Shopify StaffMember permission and plan requirements](https://shopify.dev/docs/api/admin-graphql/2026-07/objects/StaffMember)
- [Square List Customers](https://developer.squareup.com/reference/square/customers-api/list-customers)
- [Square Search Team Members](https://developer.squareup.com/reference/square/team-api/search-team-members)
- [SwipeSimple Appointments separate customer directory](https://support.swipesimple.com/hc/en-us/articles/30808240675095-Customers-in-SwipeSimple-Appointments)

No production contact records, exports, credentials or session data belong in this repository.
