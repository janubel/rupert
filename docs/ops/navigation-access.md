# Navigation and access levels

Reviewed 2026-10-15. Rupert keeps everyday work areas named and uses small labelled icons for utilities. Access is enforced by the server as well as by the visible navigation.

## Find the right tool

Use the named **Overview, Sell, Stock, Money, Work, Team and System** areas that your account can access. Each area has a consistent local icon. Areas without available work are omitted; personal time and the feature roadmap stay in the account menu when broader Team or System access is unavailable.

Inside a work area, open the current-tool dropdown to see its permitted tools with their full names. This replaces the long second row of tabs. The current tool is marked. The account menu shows your role, personal time clock, feature roadmap and sign-out action.

The magnifying glass opens search. The circular arrows show the latest recorded sync status and link to Sync for users with sync-read permission. The four-square icon opens the private instance overview for platform administrators. Icon controls retain accessible names, hover/focus descriptions and keyboard focus. Sync status describes a recorded run, not continuous provider health.

Tools menus open using Enter or Space. Tab moves through links; Escape closes the menu and returns focus to its trigger. Native tool disclosures remain usable without JavaScript. The public GitHub Pages header separately groups documentation under **Guides**, with Home, Roadmap and Compare kept close at hand. Public documentation grants no application access.

## Built-in roles

These are the defaults. Store administrators can intentionally delegate supported business permissions. Custom role or person overrides may narrow or expand business access; they cannot grant the platform-administrator role or bypass the role-only boundaries below.

| Role | Default work |
| --- | --- |
| Reader | Read-only sales, customers, inventory, reports and ledger. No company-wide personnel, timesheet, leave or payroll access. This is the automatic role for a new Google user on an enabled company domain. |
| Cashier | Sales and POS work, customer lookup, inventory and alerts. No provider setup, personnel administration or platform access. |
| Inventory staff | Inventory work and alerts, with catalog-link review. No sales/customer search or payroll by default. |
| Reporting | Read-only sales, inventory, reports and ledger. No customer-directory or personnel access by default. |
| Manager | Business operations, customer/inventory/project work and operational team, timesheet and leave work. Payroll requires explicit delegation. |
| Store administrator | Workspace business administration, provider settings, users, permissions and private owner records. Whole-instance administration remains separate. |
| Platform administrator | Cross-workspace setup review, instance totals, host diagnostics, whole-database backup/restore and instance Drive backup configuration/history, plus workspace administration. |

Personal time-clock actions still require an active employee linked to the signed-in account and remain limited to that person's records. A role label does not create an employee or authorize editing someone else's time.

## Boundaries that stay enforced

Dashboard and search require dashboard-read permission. Search checks each result category's own permission: sales for orders, customers for contacts, inventory for catalog results and HR for employee results. Dashboard widgets and their underlying reads are filtered by the required business permissions. Permission-aware cache keys prevent a prior response from remaining available after access changes.

Employee details require HR access. Pay rates and pay results additionally require payroll-read permission; timesheets and leave require their respective read permissions. Merely receiving HR or reader access does not expose every personnel section.

User/permission mutations require an active store or platform administrator with the required user-write permission. Delegating user-write to a cashier or reader does not allow promotion to administrator or arbitrary permission grants. Platform administrators remain separately protected.

Private owner records require the store/platform administrator role. Instance overview, host diagnostics and whole-database backup/restore require the platform-administrator role. Those role-only boundaries cannot be delegated through ordinary permission checkboxes. Inactive users and workspaces are rejected.

Google Drive backups contain the entire shared instance database, across every workspace. Only a platform administrator can configure or authorize its destination, view connection status/history or disconnect it. The operator approves the destination by configuring instance Drive credentials in Settings → Environment and completing Google consent; trusted host configuration can also supply these values. Existing workspace-level Drive settings and connections are ignored, with no automatic migration or approval. Scheduled uploads run once per instance every six hours only when the platform connection is configured. Disconnect disables the instance connection, including any refresh token supplied by host configuration.

Size-definition membership edits require settings-write permission. Navigation to Sizes requires settings-read; POS navigation also requires its sales and inventory prerequisites. Entering a URL directly still encounters the server permission check.

Saved OAuth secrets are never prefilled in settings HTML. Writable administrators can supply a replacement; a blank field retains the existing secret, and removal is explicit. Read-only settings access does not expose saved secrets or credential-edit controls.

See [private workspace administration](https://techmore.github.io/rupert/private-workspaces.html), [owner records](https://techmore.github.io/rupert/owner-checklists.html) and [POS setup](https://techmore.github.io/rupert/payment-integrations.html) for the separate setup and acceptance steps. Icons, role assignment and setup records do not enable planned payment or inventory features.
