# frozen_string_literal: true

# In-app help: "how to use this page" guides keyed by ModuleRegistry key. The
# shell renders PageGuides.for(active_module_entry.key) at the top of each
# module page. Content is written for real usage — what the page shows and how
# to get the most out of it.
class PageGuides
  Guide = Struct.new(:key, :title, :summary, :sections, :tips, keyword_init: true)

  GUIDES = {
    'influencers' => Guide.new(
      key: 'influencers', title: 'Influencer collaborations',
      summary: 'Track prospects, campaign collaborations, product gifts, temporary code records and documents.',
      sections: [
        { heading: 'Directory and follow-up', body: 'Add a prospect, audience topics and relationship owner. Update stages and follow-up dates as you work. Contact details and conversations require the separate Marketing contacts permission. No outreach is sent automatically.' },
        { heading: 'Collaborations and gifts', body: 'Connect a prospect to a Marketing campaign. Propose products from the mirrored Shopify catalog, record estimated costs, approve the gift and confirm recipient details. Record actual shipment and delivery evidence; this workflow does not reserve stock, create orders or change inventory.' },
        { heading: 'Offers and documentation', body: 'Create a Shopify discount draft, review its store, dates and full terms, then explicitly create the code. Marketing discounts and review access are required. Copying verifies Shopify and supplies a link that applies the code. Existing-code records and versioned campaign documents remain available; links do not measure conversions or commissions.' }
      ],
      tips: ['Do not contact blocks new offer sharing and product handoffs.', 'Document edits create a new revision and reset review.', 'Shopify-created codes enforce their saved expiry; existing-code records need matching expiry in the merchant store.']
    ),
    'marketing' => Guide.new(
      key: 'marketing', title: 'Community marketing',
      summary: 'Find topic discussions, save thread context and review replies with existing group offers.',
      sections: [
        { heading: 'Find and triage', body: 'Create a campaign and group with topic terms and promotion rules. Open the group topic search, save a discussion URL and excerpt, then mark it relevant and confirm current context.' },
        { heading: 'Review an offer and reply', body: 'Record an existing merchant code and full terms. A reviewer confirms merchant evidence for 24 hours and group rules for 30 days. Save and submit a reply with clear brand affiliation; approve the exact revision before copying it.' },
        { heading: 'Manual publication', body: 'Publish the approved text yourself and record its URL. Changed context or offers require another review. Rupert does not crawl sources, post replies or create merchant codes in this phase.' }
      ],
      tips: ['Thread context expires after 7 days. Confirm it again when needed.', 'Keep a useful contribution in each reply and follow group promotion rules.', 'An approved draft is not evidence of publication or sales.']
    ),
    'dashboard' => Guide.new(
      key: 'dashboard', title: 'Dashboard',
      summary: "Your at-a-glance store health: today's money, sales volume, and anything needing attention like inventory drift or low stock.",
      sections: [
        { heading: "What you're seeing",
          body: 'Sales cards and charts use paid canonical orders and completed native C-Trax orders. Each native C-Trax order is counted once by source, store and order ID. Source pull times and latest sale dates describe different kinds of coverage; a recent pull can contain older sales.' },
        { heading: 'How to read the numbers',
          body: "Sales are recorded USD totals from paid and fulfilled orders plus completed C-Trax sales. C-Trax tips remain separate. Payment reports, invoices and deposits are never added. Refunds require separate source review. Yesterday is the whole previous day; the last 7 and 30 days include today. Missing imports do not prove zero activity." }
      ],
      tips: [
        "Check the attention rail first every morning — it's ordered by severity.",
        'Quantity differences between Shopify and Square are normal (two locations, two inventories). Only SKU mismatches need action, on the Catalog Links page.',
        'Customize which widgets you see from the customize control, not the code.'
      ]
    ),
    'sales' => Guide.new(
      key: 'sales', title: 'Sales',
      summary: 'Recorded sales across channels and a separate canonical order journal, filtered by date and source.',
      sections: [
        { heading: "What you're seeing",
          body: "Summary and charts include USD paid/fulfilled canonical orders and completed native C-Trax orders once. The chart period ends on the selected business date. Payments, tips and deposits are separate. The canonical journal shows each order's own currency and selected status; C-Trax receipts stay in daily close." },
        { heading: 'The source toggle',
          body: 'All / Shopify / C-Trax / Square filters the selected source — useful to see online vs in-store separately. The choice is in the URL, so you can bookmark a filtered view.' }
      ],
      tips: [
        "Use the source toggle to verify a Square outage didn't lose POS sales.",
        'Jump to yesterday (or a specific day) with the date picker to close the previous shift.',
        'Print an invoice or packing slip from this page for the shipping desk.'
      ]
    ),
    'inventory_exceptions' => Guide.new(
      key: 'inventory_exceptions', title: 'Inventory exceptions',
      summary: 'A read-only review queue for uncertain stock, local hold shortages and catalog conflicts, organized by exact source item and location.',
      sections: [
        { heading: 'What needs review',
          body: 'The queue flags negative, unknown or stale mirrored stock; local holds that exceed available capacity; duplicate SKUs or barcodes; shared or unresolved catalog identities; pending counts; depleted bulk lots; and Shopify orders with incomplete source lines. Shopify and Square hold independent stock. Different channel quantities alone are not an exception.' },
        { heading: 'Filters and coverage',
          body: 'Choose a platform, stock location, work type and snapshot age threshold of 1–168 hours. Stock, holds and counts use the platform/location filters. Catalog checks cover all locations, and local bulk lots cover the store because they have no platform/location assignment. Incomplete Shopify order locations are matched by source location ID. Read each coverage note before treating a filtered view as complete.' },
        { heading: 'Reading limits and next steps',
          body: 'The queue displays bounded query results and sampled identity members, with additional pages when needed. Counts describe returned exception rows, not a complete audit or unique product count. Unknown quantities and unverifiable hold shortages stay unknown. Follow a review link to inspect the item, catalog decision, local holds, count or lot. The queue does not change stock, SKUs or material balances, and incomplete source lines must be verified before gram deductions.' }
      ],
      tips: [
        'Local holds are advisory: Shopify and Square can still sell the same stock, and a later import may reduce capacity.',
        'Check the exact source item and location before using a physical count; legacy worksheet comparisons may span Shopify locations.',
        'A recent mirror timestamp and an empty queue do not prove current physical stock. Limits, missing source data and upstream transformations can hide issues.'
      ]
    ),
    'inventory' => Guide.new(
      key: 'inventory', title: 'Stock comparison',
      summary: 'Read-only Shopify and C-Trax observations of shared stock, with current catalog coverage and source read times.',
      sections: [
        { heading: 'Read the source states', body: 'Select one Shopify location and one C-Trax store. Shopify on-hand, available and committed quantities are separate. C-Trax retains signed stock. These are observations of shared stock; never add their quantities together.' },
        { heading: 'Review identities and exceptions', body: 'Unique native variant IDs take precedence. Unique SKU/barcode identifiers are candidates, not approved mappings. Exact product words and explicit packages can suggest additional candidates, with both source names and matching evidence. These name/package candidates have no quantity difference. Duplicate or conflicting identities stay unresolved. Historical Shopify candidates explain unmatched C-Trax items without restoring old stock. Unknown stock is not zero; no current match does not mean not carried.' }
      ],
      tips: [
        'Search either source name, SKU, barcode, native ID or investigation note. Attention, unmatched, product/package, saved-findings and historical filters also apply to CSV.',
        'Older-than-one-hour, unknown, fractional or untracked observations have no numerical difference.',
        'Current active tracked Shopify variants are shown; archived, absent and unverified historical records are excluded. This page never changes stock, SKUs or mappings.'
      ]
    ),
    'reconcile' => Guide.new(
      key: 'reconcile', title: 'Catalog Links',
      summary: 'Which items are the same across Shopify and Square — a read-only identity audit. Shopify and Square are separate locations with separate stock, so quantities here are informational, never corrected.',
      sections: [
        { heading: "What you're seeing",
          body: "A row per linked item with its Shopify and Square names, SKUs, and current counts. 'Matched' means both platforms agree on the SKU. 'Mismatched' means the same item is identified differently on each side — those float to the top. Search by product or either source SKU and filter mismatches first. Size families are reference details below; review changes in the Sizes workspace." },
        { heading: 'What to do about mismatches',
          body: "A mismatch is a labeling decision, not an emergency: pick one canonical SKU and apply it on both platforms (SKU writes always get owner sign-off first), or unlink if they're truly different items. Nothing here writes automatically." }
      ],
      tips: [
        'Run a sync after creating new SKUs so new items appear as linked.',
        'One-sided counts (Shopify-only / Square-only) are expected — wholesale and event stock often lives on just one platform.',
        'Size-derived SKUs are handled by the root gram math on the Sizes page.'
      ]
    ),
    'sizes' => Guide.new(
      key: 'sizes', title: 'Sizes',
      summary: 'Multi-size gram products derived from a root gram bank. Every 15-minute sync folds in sales and recomputes each size as floor(root grams ÷ size grams).',
      sections: [
        { heading: "What you're seeing",
          body: "Each family card shows its root gram bank (the source of truth) and every size with current vs derived target. 'Pending approvals' lists recomputed sizes awaiting your sign-off before they're written to Square." },
        { heading: 'Root grams & modes',
          body: "Set root grams after a physical count — it's the number every size derives from. 'Approval-only' queues changes for review; 'auto-apply' writes them every sync. A size showing 'in sync' needs nothing." }
      ],
      tips: [
        "After a physical count of the flower, hit 'Set root grams' — it resets the sales watermark so prior sales aren't double-counted.",
        'Keep families on approval-only until you trust the math, then flip to auto.',
        "Approve pending sizes in one click; rejected math shows as 'failed' with the reason."
      ]
    ),
    'warehouse' => Guide.new(
      key: 'warehouse', title: 'Warehouse',
      summary: 'Wholesale pages for vendors — secret links with a negotiated price multiplier and bulk discount tiers.',
      sections: [
        { heading: "What you're seeing",
          body: "Global bulk tiers apply to every vendor by default; each vendor link can override them with custom tiers. The vendor's page shows list price, their multiplier, and a per-tier price breakdown at 10+, 25+, etc." },
        { heading: 'How pricing works',
          body: 'Vendor price = list × multiplier, then bulk tiers stack a % off at quantity thresholds. The link token in the URL is the only access control — share it privately.' }
      ],
      tips: [
        'Create one link per customer and set their negotiated multiplier (e.g. 0.85 = 15% off list).',
        "Set custom bulk tiers per vendor when one customer's deal differs from the global schedule.",
        'Deactivate a link (not delete) when a customer relationship pauses — the URL stops working instantly.'
      ]
    ),
    'activity' => Guide.new(
      key: 'activity', title: 'Activity',
      summary: 'The audit trail — who did what, to which record, and when.',
      sections: [
        { heading: "What you're seeing", body: 'A chronological log of business actions: employee changes, permission edits, and other write operations with the actor and the record they touched.' }
      ],
      tips: [
        'Pair this with the Access log — Activity is what happened in the app, Access log is who signed in from where.'
      ]
    ),
    'access_log' => Guide.new(
      key: 'access_log', title: 'Access log',
      summary: 'Every sign-in attempt — who tried, from which IP, when, and whether it worked — so you can spot brute force or unwanted access.',
      sections: [
        { heading: "What you're seeing",
          body: 'One row per authentication event: the person (or attempted email), the domain they tried, the method (password / Google / sign-out), status, IP address, and a reason for failures (unknown email, bad password, domain not allowed, rate limited).' },
        { heading: 'Reading failures',
          body: "A spike of 'failure' rows from one IP means someone is guessing passwords. Repeated rows for one email mean that account is being targeted — the login throttle auto-blocks after 10 per IP / 5 per email in 15 minutes." }
      ],
      tips: [
        'Filter by Status = failure and look at the IP column to spot attackers.',
        "The 'attempt' rows are Google sign-ins that started but may have been cancelled before completing.",
        "Rate-limited attempts are logged but don't extend the lockout."
      ]
    ),
    'sync' => Guide.new(
      key: 'sync', title: 'Sync',
      summary: 'Pull Shopify + Square into Rupert. Runs automatically every 15 minutes; here you can run it manually and see the history.',
      sections: [
        { heading: "What you're seeing", body: 'The last sync runs with status and drift. Manual controls let you trigger a full sync or just one source (Shopify or Square) — useful after you change a SKU or fix inventory in one platform.' }
      ],
      tips: [
        'After creating products/SKUs in Shopify or Square, run a sync so the links appear.',
        'A failed sync shows the error here — most are transient; the next scheduled run recovers.'
      ]
    ),
    'settings' => Guide.new(
      key: 'settings', title: 'Settings',
      summary: "Your store's configuration — business details, Google sign-in, size families, warehouse links and the Buzz agent. Platform administrators also manage instance backups.",
      sections: [
        { heading: "What's here", body: 'Business name and invoice prefix; Google OAuth (allowed domains + client credentials); size families (root gram products); the wholesale Warehouse link; and the Buzz agent identity. Google Drive backup controls are restricted to the platform super administrator.' }
      ],
      tips: [
        'Only the platform super administrator configures Google Drive backups. Every 6 hours, Rupert can copy the entire shared instance database to that approved destination; store credentials cannot authorize this.',
        'Add every staff email domain to Google sign-in; new people on an allowed domain get a employee account automatically.',
        'Environment secrets (Square/Shopify tokens) live in the .env card and are encrypted at rest.'
      ]
    ),
    'employees' => Guide.new(
      key: 'employees', title: 'Employees',
      summary: 'Your team directory — who works where, linked to their login accounts.',
      sections: [
        { heading: "What you're seeing", body: 'Every employee with their role/position and, where set, the login account they use to sign in. Roles drive what each person can see and do.' }
      ],
      tips: [
        'Link an employee to a login account so their work (timesheets, sales) is attributed to them.',
        'Manage what they can access on the Permissions screen, not by editing the role matrix directly.'
      ]
    ),
    'timesheets' => Guide.new(
      key: 'timesheets', title: 'Timesheets',
      summary: 'Clock-in tracking for the team — time worked per employee and shift.',
      sections: [
        { heading: "What you're seeing", body: 'Timesheet entries with in/out times, submitted, reviewed, and approved states. Approvals feed payroll.' }
      ],
      tips: [
        'Review and approve on the day or week — it keeps payroll smooth and disputes rare.'
      ]
    ),
    'payroll' => Guide.new(
      key: 'payroll', title: 'Payroll',
      summary: 'Run pay periods from approved time — draft runs, finalize, and generate payslips.',
      sections: [
        { heading: "What you're seeing", body: 'Pay runs built from approved timesheets, with finalize and payslip steps. Drafts are editable; finalized runs are locked.' }
      ],
      tips: [
        'Only approved hours flow into a pay run — approve timesheets first.'
      ]
    ),
    'users' => Guide.new(
      key: 'users', title: 'Accounts',
      summary: 'Who can sign in and their role. Also the per-person permission overrides.',
      sections: [
        { heading: "What you're seeing", body: 'The login accounts (which pair with employees) and their roles: super_admin, admin, manager, cashier, reader. Super admin is platform-wide; everything else is scoped to this store.' }
      ],
      tips: [
        'Give the least privilege that works — readers can view, managers can run, admins configure.',
        'Use per-person overrides sparingly; role defaults keep things predictable.'
      ]
    ),
    'permissions' => Guide.new(
      key: 'permissions', title: 'Permissions',
      summary: 'The catalog of every permission in the system and how roles map to them.',
      sections: [
        { heading: "What you're seeing", body: 'Every capability grouped by area (Sales, Inventory, System, Team). Role overrides let you change what a role can do store-wide, and per-employee overrides on the Accounts page fine-tune one person.' }
      ],
      tips: [
        "An override replaces the role's built-ins for that person — keep the list complete when you add one."
      ]
    ),
    'finance' => Guide.new(
      key: 'finance', title: 'Finance',
      summary: 'Chart of accounts, expenses, and vendor payments — the books that tie sales to money out.',
      sections: [
        { heading: "What you're seeing", body: 'Your chart of accounts, expense records, and vendor payments. Vendor credits, purchase commitments and received balances remain separate. Customer receivables are grouped by currency. These local records do not establish a bank balance or a complete accounting profit.' }
      ],
      tips: [
        'Keep the chart of accounts tidy — reports read straight from it.'
      ]
    ),
    'purchasing' => Guide.new(
      key: 'purchasing', title: 'Purchasing',
      summary: "Vendors and purchase orders — what you buy and what you've received.",
      sections: [
        { heading: "What you're seeing", body: 'A vendor list and purchase orders with placed → received → cancelled states. Receiving a PO moves goods into inventory.' }
      ],
      tips: [
        'Receive POs promptly so inventory reflects stock arriving, not just sales leaving.'
      ]
    ),
    'reports' => Guide.new(
      key: 'reports', title: 'Reports',
      summary: 'Financial and operational reports — sales, money, inventory, and operations.',
      sections: [
        { heading: "What you're seeing", body: 'Report views for sales, financials, inventory, and operations, pulled from the mirrored data. Export options let you take numbers to spreadsheets.' }
      ],
      tips: [
        'Run a sync first so reports always use the freshest data.'
      ]
    ),
    'ledger' => Guide.new(
      key: 'ledger', title: 'Ledger',
      summary: 'Imported order ledger observations by source and currency.',
      sections: [
        { heading: "What you're seeing", body: 'This legacy mirror can describe orders already included in sales. Its currency totals stay separate and are not added to revenue, gateway payments or bank deposits. Financial close retains source controls and reviewer conclusions.' }
      ],
      tips: [
        'Use financial close for original evidence and bank verification. Missing imports are not proof of zero activity.'
      ]
    ),
    'alerts' => Guide.new(
      key: 'alerts', title: 'Alerts',
      summary: "Low-stock and exception alerts so you restock before you're out.",
      sections: [
        { heading: "What you're seeing", body: 'Stock alerts per SKU with the current count vs threshold, plus open/resolved status so you can track follow-through.' }
      ],
      tips: [
        'Resolve alerts as you reorder — open alerts are the work queue.'
      ]
    ),
    'customers' => Guide.new(
      key: 'customers', title: 'Customers',
      summary: 'Everyone who buys — orders, contact info, and history in one place.',
      sections: [
        { heading: "What you're seeing", body: "The customer list, searchable, with their order history. Opening a customer shows the orders they've placed across channels." }
      ],
      tips: [
        'Search by name, phone, or email — not just order number.'
      ]
    ),
    'connections' => Guide.new(
      key: 'connections', title: 'Master credentials & sync',
      summary: 'One setup desk for saved credentials, source freshness, access checks and repair steps.',
      sections: [
        { heading: "What you're seeing", body: 'Credential completeness and actual source freshness are separate. Open a connection to replace credentials, explicitly check access, then run a read. Saved secrets stay hidden; backup setup remains with the platform operator.' }
      ],
      tips: [
        'If access checks pass but data stays stale, review Sync history and Worker status. Do not replace credentials or enable a schedule merely because a source is stale.'
      ]
    ),
    'system' => Guide.new(
      key: 'system', title: 'System',
      summary: 'Health and diagnostics for the app itself.',
      sections: [
        { heading: "What you're seeing", body: 'Runtime info and diagnostics to confirm the system is healthy and which version is running.' }
      ],
      tips: [
        'Reference the version here when reporting an issue.'
      ]
    ),
    'registers' => Guide.new(
      key: 'registers', title: 'Registers',
      summary: 'Open and close POS register sessions — the cash drawer lifecycle for the storefloor.',
      sections: [
        { heading: "What you're seeing", body: "Each register session with its open/closed state. Opening a session starts the drawer; closing it reconciles what's in it and locks it for review." }
      ],
      tips: [
        'Close a register at the end of a shift so cash can be verified against sales.',
        'Reopen only to correct a mistaken close, then close again.'
      ]
    ),
    'locations' => Guide.new(
      key: 'locations', title: 'Locations',
      summary: 'Where stock lives — Shopify and Square locations plus any manual ones.',
      sections: [
        { heading: "What you're seeing", body: 'Each location with its source (shopify/square/manual), kind, unit count, and status. Inventory levels are tracked per location.' }
      ],
      tips: [
        "Keep one 'home' location authoritative for Square counts — reconciliation targets it.",
        'Rename a location here without touching Shopify/Square; the external ID stays linked.'
      ]
    ),
    'inventory_counts' => Guide.new(
      key: 'inventory_counts', title: 'Inventory counts',
      summary: "Physical count sheets record what is on the shelf for review and approval.",
      sections: [
        { heading: "What you're seeing", body: 'Count sheets in draft/submitted/approved states. Approval preserves the reviewed physical count as an audit record; it does not change Shopify or Square quantities.' }
      ],
      tips: [
        'Run a count before trusting the mirror after a big discrepancy.',
        'Review prepared quantities before scanning: use Set total for the first physical count of each SKU.'
      ]
    ),
    'projects' => Guide.new(
      key: 'projects', title: 'Projects',
      summary: 'Track initiatives end to end — owners, phases, and current status.',
      sections: [
        { heading: "What you're seeing", body: 'Projects with their stage and task counts. Open a project to see its tasks and move work through your workflow.' }
      ],
      tips: [
        'Move projects through statuses as work completes so the pipeline stays honest.'
      ]
    ),
    'tasks' => Guide.new(
      key: 'tasks', title: 'Tasks',
      summary: "Every task across all projects in one list — the team's to-do board.",
      sections: [
        { heading: "What you're seeing", body: "All tasks with their project and status, so nothing is buried inside a project you're not looking at." }
      ],
      tips: [
        "Use this list as the daily stand-up — sort by project or status to see what's open."
      ]
    ),
    'goals' => Guide.new(
      key: 'goals', title: 'Goals',
      summary: 'Business goals you set and track progress against.',
      sections: [
        { heading: "What you're seeing", body: 'Goals with targets and current progress, updated as KPIs move.' }
      ],
      tips: [
        'Attach a KPI to each goal so progress updates automatically.'
      ]
    ),
    'kpis' => Guide.new(
      key: 'kpis', title: 'KPIs',
      summary: 'The measures that tell you whether goals are being met.',
      sections: [
        { heading: "What you're seeing", body: 'KPI definitions and their readings over time, linked to the goals they serve.' }
      ],
      tips: [
        'Record readings on a cadence — a KPI without recent readings is just a number.'
      ]
    ),
    'departments' => Guide.new(
      key: 'departments', title: 'Departments',
      summary: 'Your org structure — the teams people belong to.',
      sections: [
        { heading: "What you're seeing", body: 'Departments that employees belong to. They drive reporting and who sees what in the team area.' }
      ],
      tips: [
        'Keep this small and stable; move people between departments, not the departments around them.'
      ]
    ),
    'positions' => Guide.new(
      key: 'positions', title: 'Positions',
      summary: 'The roles people fill — cashier, manager, etc. — independent of login permissions.',
      sections: [
        { heading: "What you're seeing", body: 'Position titles you can assign to employees. Positions describe the job; login permissions control system access.' }
      ],
      tips: [
        'Assign a position to every employee so the directory and reports read cleanly.'
      ]
    ),
    'leave' => Guide.new(
      key: 'leave', title: 'Leave & PTO',
      summary: 'Time-off requests from the team, approved or denied.',
      sections: [
        { heading: "What you're seeing", body: 'Leave requests with their status. Approving or denying them keeps the schedule and payroll accurate.' }
      ],
      tips: [
        "Respond to requests promptly so the team isn't guessing about coverage."
      ]
    )
  }.freeze

  # Path prefix -> guide key, most-specific first. Matched by the shell so help
  # appears automatically on the right page regardless of module-registry keys.
  PATH_MAP = [
    ['/size_families', 'sizes'],
    ['/access_logs', 'access_log'],
    ['/sales/pos_sessions', 'registers'],
    ['/inventory_counts', 'inventory_counts'],
    ['/inventory_exceptions', 'inventory_exceptions'],
    ['/people/employees', 'employees'],
    ['/people/timesheets', 'timesheets'],
    ['/people/pay_runs', 'payroll'],
    ['/people/leave_requests', 'leave'],
    ['/people/departments', 'departments'],
    ['/people/positions', 'positions'],
    ['/projects/projects', 'projects'],
    ['/projects/tasks', 'tasks'],
    ['/goals/goals', 'goals'],
    ['/goals/kpis', 'kpis'],
    ['/finance', 'finance'],
    ['/purchasing', 'purchasing'],
    ['/sales', 'sales'],
    ['/stock_comparison', 'inventory'],
    ['/inventory', 'inventory'],
    ['/reconcile', 'reconcile'],
    ['/warehouse', 'warehouse'],
    ['/activity', 'activity'],
    ['/syncs', 'sync'],
    ['/settings', 'settings'],
    ['/employees', 'employees'],
    ['/users', 'users'],
    ['/permissions', 'permissions'],
    ['/reports', 'reports'],
    ['/ledger', 'ledger'],
    ['/alerts', 'alerts'],
    ['/customers', 'customers'],
    ['/connections', 'connections'],
    ['/system', 'system']
  ].freeze

  class << self
    def for(key)
      GUIDES[key.to_s]
    end

    def for_path(path)
      return GUIDES['dashboard'] if path.to_s == '/'

      match = PATH_MAP.find { |prefix, _| path.to_s.start_with?(prefix) }
      match && GUIDES[match.last]
    end

    def keys
      GUIDES.keys
    end
  end
end
