# frozen_string_literal: true

# In-app help: "how to use this page" guides keyed by ModuleRegistry key. The
# shell renders PageGuides.for(active_module_entry.key) at the top of each
# module page. Content is written for real usage — what the page shows and how
# to get the most out of it.
class PageGuides
  Guide = Struct.new(:key, :title, :summary, :sections, :tips, keyword_init: true)

  GUIDES = {
    # Stock
    'stock_requests' => Guide.new(
      key: 'stock_requests', title: 'Transfers and backorders',
      summary: 'Record a stock transfer between locations or a backorder for waiting demand, then confirm each physical step as it happens.',
      sections: [
        { heading: 'Transfers', body: 'A transfer reserves one native item at its source location, records dispatch, then records receipt at the destination. Partial receipts stay in transit until every unit arrives. Each confirmation asks for the source stock adjustment reference and time because the adjustment itself is made in Shopify, Square or C-Trax by a person.' },
        { heading: 'Backorders', body: 'A backorder records demand at a fulfillment location. Allocating sets units aside in Rupert and lowers advisory availability; fulfilling confirms the handover. Waiting demand holds no stock, and cancelling releases the hold.' }
      ],
      tips: ['Rupert never writes quantities to a platform; refresh source stock after you adjust it there.', 'Quantity / received shows requested units against units confirmed so far.', 'Use the event history on a request to see who confirmed each step and when.']
    ),
    'stock_reservations' => Guide.new(
      key: 'stock_reservations', title: 'Stock reservations',
      summary: 'Local holds that reduce Rupert’s available-to-promise for one platform item at one location.',
      sections: [
        { heading: 'What a hold does', body: 'A reservation lowers the advisory availability Rupert shows for that exact source item and location. It does not reserve stock in Shopify or Square, so a channel can still sell the units and a later sync can reduce availability further.' },
        { heading: 'Lifecycle', body: 'Holds created by a transfer or backorder are released through that request. Manual holds can be released here; expired holds stop consuming availability automatically.' }
      ],
      tips: ['Set an expiry so forgotten holds do not hide sellable stock.', 'Shopify and Square pools stay separate; one hold applies to one pool.']
    ),
    'bulk_materials' => Guide.new(
      key: 'bulk_materials', title: 'Bulk materials',
      summary: 'Track raw material by material and lot inside Rupert, with receipts, consumption and an append-only movement ledger.',
      sections: [
        { heading: 'Materials and lots', body: 'Create a material, then receive lots against it. Each lot keeps its own code, note and remaining balance in whole milligrams; decimal inputs round once to the nearest milligram.' },
        { heading: 'Consumption', body: 'Material leaves a lot through sale material-use receipts or manual movements. The ledger is append-only, so corrections are new entries rather than edits.' }
      ],
      tips: ['This ledger never changes Shopify or Square quantities or SKUs.', 'Export the ledger CSV for a spreadsheet; Sheets synchronisation is not automatic.']
    ),
    'bulk_recipes' => Guide.new(
      key: 'bulk_recipes', title: 'Bulk recipes',
      summary: 'Map an exact Shopify variant to grams of one raw material per sold unit.',
      sections: [
        { heading: 'Versions', body: 'Every recipe definition is a new immutable version with an effective time. Material-use receipts keep the version they were applied with, so changing a recipe never rewrites history.' },
        { heading: 'Identity', body: 'Recipes attach to the exact source variant ID, never to a SKU. A reused SKU does not select a recipe.' }
      ],
      tips: ['Record lot receipts under Bulk materials before applying recipes to sales.', 'Review imported sale lines under Sale material use to apply a recipe.']
    ),
    'bulk_consumptions' => Guide.new(
      key: 'bulk_consumptions', title: 'Sale material use',
      summary: 'Review imported Shopify sale lines and record the raw material each one consumed from a chosen lot.',
      sections: [
        { heading: 'Readiness', body: 'Only complete, uncancelled, paid Shopify snapshots with exact source IDs and matching positive whole-unit quantities can be applied. Missing, legacy, reduced-quantity, truncated and refunded snapshots stay blocked until reviewed.' },
        { heading: 'Receipts', body: 'Each source sale line can deduct once, producing an immutable material-use receipt that names the lot and recipe version. Refunds never return material automatically.' }
      ],
      tips: ['Verify the physical sale; a clean snapshot does not prove the order was never edited.', 'Independent platform stock is unchanged by anything recorded here.', 'Export receipts recorded in a date range as CSV.']
    ),
    'vendors' => Guide.new(
      key: 'vendors', title: 'Vendors',
      summary: 'Who the shop buys from, with contact details, payment terms and purchase-order history.',
      sections: [
        { heading: 'Directory', body: 'Add a vendor with contact, email and payment terms. The list shows how many purchase orders exist and how many are still open (draft or ordered).' },
        { heading: 'Balances', body: 'What is owed to a vendor after payments is on the Accounts page, not here. Vendor payments are recorded under Payments to vendors.' }
      ],
      tips: ['Payment terms are a note for people; nothing is scheduled or paid automatically.', 'Open a vendor to start a purchase order for them.']
    ),
    'purchase_orders' => Guide.new(
      key: 'purchase_orders', title: 'Purchase orders',
      summary: 'What has been ordered from vendors and what has arrived, line by line.',
      sections: [
        { heading: 'Draft to received', body: 'Build lines on a draft (item, SKU, quantity, unit cost), place the order, then record cumulative received quantities as deliveries arrive. Ordered value is quantity × unit cost; Owed to vendor on an order is the ordered value not yet received.' },
        { heading: 'Stock', body: 'Receiving records the delivery locally. Platform stock is adjusted separately in the source system; refresh source stock in Rupert afterwards.' }
      ],
      tips: ['Enter the total received so far for each line, including earlier deliveries.', 'Cancelling an ordered PO records the decision; it does not notify the vendor.']
    ),
    # Money
    'bookkeeping' => Guide.new(
      key: 'bookkeeping', title: 'Bookkeeping overview',
      summary: 'One month of bank activity for a selected account beside recorded expenses, pending decisions and links to the statements.',
      sections: [
        { heading: 'Bank figures', body: 'Statement balance is the closing balance on the latest retained statement. Money in, money out and net cash movement add every statement line for the month, including transfers. Rupert has no live bank connection.' },
        { heading: 'Decisions', body: 'Bank lines wait until you say what they were. The review banner counts lines decided, pending and flagged; Needs your attention lists the oldest open questions.' }
      ],
      tips: ['The default month is the latest imported activity for the selected account.', 'This overview does not certify reconciliation or calculate profit; use the income statement for posted results.']
    ),
    'books_desk' => Guide.new(
      key: 'books_desk', title: 'Close and review',
      summary: 'The weekly desk for closing days, reviewing differences and approving finished periods, in order.',
      sections: [
        { heading: 'Work the list', body: 'Each day shows its close checks, review state and retained package. Open a day to gather source reports, compare them with imported records and record your review.' },
        { heading: 'Checks', body: 'The checks tab runs the read-only books health checks for the current window. Passing checks do not certify a bank reconciliation.' }
      ],
      tips: ['Lock a finished month under Period locks once its days are approved.', 'A changed fingerprint means evidence moved after a review; look again before relying on it.']
    ),
    'book_approvals' => Guide.new(
      key: 'book_approvals', title: 'Book approvals',
      summary: 'Look over a day’s or week’s numbers, then record a signed decision in a tamper-evident ledger.',
      sections: [
        { heading: 'What you approve', body: 'Money in by source and currency, money out from expenses and vendor payments, and the open checks for the period. Each source and currency stays on its own line; Unavailable means the source gave no amount, not zero.' },
        { heading: 'The ledger', body: 'Your decision is stored with your name, time, network address and a fingerprint of the books it covered. If records change afterwards the approval shows as changed. Entries are never edited; a later decision is added after.' }
      ],
      tips: ['Approve with exceptions when checks remain, and explain them in the note.', 'This records a human review of Rupert’s records, not a bank reconciliation or tax filing.']
    ),
    'bank_statements' => Guide.new(
      key: 'bank_statements', title: 'Bank statements',
      summary: 'Upload a bank CSV, then say what each line was. Nothing is recorded until you choose.',
      sections: [
        { heading: 'Upload', body: 'Name the account (never the number) and upload the CSV. Tick the box if your bank lists withdrawals as positive numbers. The original is kept unchanged and encrypted, and a line is never imported twice.' },
        { heading: 'Decide', body: 'For each waiting line pick an expense category, a vendor payment or Ignore for transfers and personal items. Suggestions come from the description and are only applied when you save. Each decision keeps your name and time.' }
      ],
      tips: ['Undecided withdrawals are missing from money out until you decide them.', 'Deciding a line inside an approved day marks that approval as changed.', 'Match statement lines to ledger entries on the Bank reconciliation page.']
    ),
    'business_snapshot' => Guide.new(
      key: 'business_snapshot', title: 'Business snapshot',
      summary: 'A printable picture of sales, stock, cash and vendors built from live records, each section stating its source and age.',
      sections: [
        { heading: 'Reading it', body: 'Sales windows end today and show totals with order counts. Stock value is mirrored quantity at current price. Cash lists recorded tenders, refunds, processor deposit reports and bank statement status. Unknown means unknown, not zero.' },
        { heading: 'Saving a copy', body: 'Save a dated copy keeps an unchangeable JSON with a checksum as evidence. Printing uses the browser.' }
      ],
      tips: ['Check the data-health line first; a broken approval ledger means approvals are unverified.', 'This is an operational picture, not audited financial statements.']
    ),
    'books_check' => Guide.new(
      key: 'books_check', title: 'Books health',
      summary: 'Read-only checks on recent sales, payments, refunds and retained evidence, graded fix, watch or passing.',
      sections: [
        { heading: 'Verdict', body: 'Fix first lists records that disagree with each other, such as refunded orders with no refund amount. Worth a look flags gaps to confirm. Passing checks are listed so you can see what was tested.' },
        { heading: 'Window', body: 'Choose 7, 30, 90 or 365 days. Each check names the records it looked at and links to where they are fixed.' }
      ],
      tips: ['Nothing on this page changes data.', 'Passing checks do not certify a bank reconciliation; bank funding, fees and timing still need source evidence.']
    ),
    'period_locks' => Guide.new(
      key: 'period_locks', title: 'Period locks',
      summary: 'Lock a finished month, quarter or year so nothing dated inside it can be added, changed or removed.',
      sections: [
        { heading: 'Before locking', body: 'The checklist shows what is still open for the period. Locking saves a dated JSON archive of the totals with a checksum; a note is required while steps remain.' },
        { heading: 'After locking', body: 'Expenses, payments, bank decisions, reviews, closes and approvals dated inside the period become read-only. Source imports keep arriving; if one changes the period the page says so. Reopening needs a store administrator and a written reason, and is recorded in the lock ledger.' }
      ],
      tips: ['Start with the most recent finished month.', 'Each ledger entry carries a fingerprint that includes the previous one, so tampering is detectable.']
    ),
    'source_reports' => Guide.new(
      key: 'source_reports', title: 'Source reports',
      summary: 'Saved totals from each sales source for a day, week, month, quarter or year, shown separately and never added together.',
      sections: [
        { heading: 'Observations', body: 'Each row is one measure for one source, account scope and currency, with its evidence basis: imported orders, gateway payments, processor deposits or an uploaded report. Rows with different bases can describe the same money, so no combined total is shown.' },
        { heading: 'Saved reviews', body: 'Rupert retains the previous completed period automatically each night, week, month, quarter and year. Save / refresh keeps a snapshot of the current observations. Saving does not certify bank reconciliation or close a day.' }
      ],
      tips: ['Check source freshness before trusting a period; a missing import is not zero activity.', 'Download the CSV for a spreadsheet comparison with processor statements.']
    ),
    'financial_close' => Guide.new(
      key: 'financial_close', title: 'Day close',
      summary: 'Work one business date from source originals to a retained close package.',
      sections: [
        { heading: 'Checks first', body: 'Checks needing action list missing register reports, differences, unavailable comparisons and open follow-ups. Counts describe checks and may overlap. A current review of the evidence is required before any package can be retained.' },
        { heading: 'Retain the package', body: 'Choose Complete when checks are clear, or Close with documented exceptions and explain them. Rupert verifies the originals’ checksums and archives the reconciliation CSV with the package. Saving does not close follow-ups, post a ledger entry or send a message.' }
      ],
      tips: ['A package whose fingerprint no longer matches means evidence changed after it was retained.', 'Use Across days to see which dates still need work.']
    ),
    'cash_forecast' => Guide.new(
      key: 'cash_forecast', title: 'Cash forecast',
      summary: 'A weekly plan of bank receipts and payments built only from assumptions you enter, in one currency.',
      sections: [
        { heading: 'Inputs', body: 'Enter opening cash as of the close date, its basis, an optional minimum reserve and expected receipts and payments for each week. Blank weeks count as zero once you confirm them. Sales totals and processor deposits are not treated as bank cash.' },
        { heading: 'Results', body: 'Each week closes at opening + receipts − payments and the next week opens there. Weeks below your reserve (or below zero) are highlighted. Calculate previews; Retain saves an encrypted version with its assumptions.' }
      ],
      tips: ['Recalculate after changing inputs before downloading or retaining.', 'Nothing here moves money, reads a bank or sends messages.']
    ),
    'reconciliation_overview' => Guide.new(
      key: 'reconciliation_overview', title: 'Reconciliation across days',
      summary: 'Compare close checks, reviews and follow-ups across a week of business dates to see what still needs attention.',
      sections: [
        { heading: 'Business days', body: 'Each date shows its close checks, review state, retained package and next action. Open a day to work it in Day close.' },
        { heading: 'Report gaps and follow-ups', body: 'Register reports to request lists source pools with recorded activity but no tracked control report. Overdue and due-today follow-ups span all dates.' }
      ],
      tips: ['Only tracked expectations are known; add required invoices, bank and processor reports as follow-ups.', 'Change the ending date to review an earlier week.']
    ),
    'reconciliation_follow_ups' => Guide.new(
      key: 'reconciliation_follow_ups', title: 'Report requests and follow-ups',
      summary: 'Missing reports and differences to investigate, kept visible across business days until each is closed with a reason.',
      sections: [
        { heading: 'A follow-up', body: 'Each item has a category, period, owner, due date, notes and optionally a linked original. Record progress to add a dated note, reassign or change the due date; resolving needs a reason.' },
        { heading: 'Queues', body: 'Shortcuts filter by overdue, due today, unassigned and reports without a linked original. Items created from a missing register report carry the source, currency and location they are waiting for.' }
      ],
      tips: ['Closing a day’s evidence package does not close its follow-ups.', 'No messages are sent; assignments and due dates live only in Rupert.']
    ),
    'reconciliation_documents' => Guide.new(
      key: 'reconciliation_documents', title: 'Source documents',
      summary: 'Find the original reports, invoices, statements and archives behind the books, including every saved version, across dates.',
      sections: [
        { heading: 'Search', body: 'Filter by source, category, dates and text. Each document shows its period, checksum, versions and the day it supports. Close packages, lock archives and forecast versions appear under the Rupert source as archives.' },
        { heading: 'Versions', body: 'A corrected report is a new version; earlier versions stay available. Originals are encrypted and never deleted automatically.' }
      ],
      tips: ['Open a document’s day to see how it was used as a control.', 'Use Google Drive retention to keep an off-host second copy.']
    ),
    'retention_drive' => Guide.new(
      key: 'retention_drive', title: 'Google Drive document retention',
      summary: 'Keep an automatic second copy of retained originals and archives in a Google Drive folder.',
      sections: [
        { heading: 'Connection', body: 'A workspace administrator connects the destination account. Rupert copies original file bytes without converting them, downloads each copy back and checks it before marking it Copied.' },
        { heading: 'Status', body: 'The page lists copied, waiting and failed files and the last error. Sync now retries. Only this workspace’s retained files are copied; whole-instance backups have their own schedule.' }
      ],
      tips: ['Originals remain available in Rupert while Drive setup waits.', 'Rupert does not share or delete retention files.']
    ),
    'daily_reconciliation' => Guide.new(
      key: 'daily_reconciliation', title: 'Daily reconciliation',
      summary: 'Check one business day against its source reports, keep the originals and record anything that needs follow-up.',
      sections: [
        { heading: 'Attention', body: 'Differences compare a register control report with imported records for the same source, currency and location; Rupert minus source is the delta. Unavailable comparisons have no comparable amount and are not zero. Conflicting controls means two current reports cover the same pool.' },
        { heading: 'Evidence and review', body: 'Upload register reports, invoices and statements as controls. Record your review when done; it binds to the current evidence fingerprint and shows as changed if evidence moves.' }
      ],
      tips: ['Source, currency and location are never added together.', 'Track a missing report as a follow-up so it stays visible across days.', 'Download the CSV to keep with the close package.']
    ),
    'register_summary' => Guide.new(
      key: 'register_summary', title: 'Daily register summary',
      summary: 'Recorded sales, tenders and refunds for one day by source, location and currency, with payment-coverage diagnostics.',
      sections: [
        { heading: 'Rows', body: 'Eligible orders are paid, fulfilled or refunded orders dated on the day. Order total and recorded tax come from those orders; Tenders less refunds nets recorded payments against recorded refunds per tender type. Any unknown amount stays Unavailable rather than showing a false zero.' },
        { heading: 'Coverage and freshness', body: 'Missing, incomplete and overcovered compare each order total with all imported completed payments for that order. Source import freshness shows when each source last completed; an old CSV imported today does not establish today’s coverage.' }
      ],
      tips: ['Shopify tenders are inferred from gateway names and may use order creation time, not collection time.', 'This is an accounting comparison, not settled cash or bank deposits.']
    ),
    'finance_accounts' => Guide.new(
      key: 'finance_accounts', title: 'Accounts',
      summary: 'Vendor balances and customer receivables from Rupert’s recorded purchase orders, orders and payments.',
      sections: [
        { heading: 'Vendor balances', body: 'Balance due is received goods less recorded payments per vendor. Payments above received goods show as a credit and never offset another vendor. Ordered, not received is a purchase commitment shown separately.' },
        { heading: 'Customer receivables', body: 'Paid or fulfilled order gross less completed payments, grouped by customer and currency. A missing order amount keeps that balance Unknown.' }
      ],
      tips: ['These are local records, not bank balances or vendor invoices.', 'Record a vendor payment from the row once it has actually been paid.']
    ),
    'chart_of_accounts' => Guide.new(
      key: 'chart_of_accounts', title: 'Chart of accounts',
      summary: 'The accounts the ledger posts to, grouped by type in code order.',
      sections: [
        { heading: 'Accounts', body: 'Each account has a code, name, type and the side it increases with: assets and expenses with debits, liabilities, equity and revenue with credits. Select a code to see every entry posted to it.' },
        { heading: 'Archiving', body: 'An archived account stays on record with its history but cannot be chosen for new entries. Existing entries and reports are unchanged, and it can be restored.' }
      ],
      tips: ['Keep codes stable so exports to accounting software stay consistent.', 'Cash (1000) and Checking (1100) are the accounts bank reconciliation compares against.']
    ),
    'expenses' => Guide.new(
      key: 'expenses', title: 'Expenses',
      summary: 'Money the business has already paid out, each posting an entry to the ledger.',
      sections: [
        { heading: 'Recording', body: 'Enter the date, payee or vendor, category, method and amount. Saving posts a balanced ledger entry. Totals count active expenses in the chosen range across all pages.' },
        { heading: 'Changes', body: 'Removing an expense keeps it on the list as Removed, voids its ledger entry and can be undone. Expenses dated inside a locked period are read-only.' }
      ],
      tips: ['Many expenses arrive as bank statement decisions; recording them there avoids duplicates.', 'No money is transferred by this register.']
    ),
    'payments' => Guide.new(
      key: 'payments', title: 'Payments to vendors',
      summary: 'Payments already made against vendor purchase orders, recorded to lower the local balance due.',
      sections: [
        { heading: 'Recording', body: 'Choose the vendor, date, method, reference and amount. The payment lowers that vendor’s balance on the Accounts page and posts to the ledger.' },
        { heading: 'Changes', body: 'Removing a payment keeps it listed as Removed and can be restored. Payments inside a locked period are read-only.' }
      ],
      tips: ['Record the payment after it has left the bank; Rupert does not send money.', 'Paying more than received goods shows as a vendor credit, not a negative balance.']
    ),
    'journal_entries' => Guide.new(
      key: 'journal_entries', title: 'General ledger',
      summary: 'Every posted entry, each with equal debits and credits, newest first.',
      sections: [
        { heading: 'Entries', body: 'Expenses, vendor payments and sales create entries automatically; manual and opening entries are posted by people. Totals on this page include void entries shown in the list; reports and exports leave them out.' },
        { heading: 'Corrections', body: 'Posted entries are never edited. Reverse a manual entry to post one that swaps every debit and credit; to correct a generated entry, change or remove its source record and the ledger follows.' }
      ],
      tips: ['Filter by account to audit one balance.', 'Entries dated inside a locked period cannot change.']
    ),
    'finance_reports' => Guide.new(
      key: 'finance_reports', title: 'Financial reports',
      summary: 'Trial balance, income statement and balance sheet computed from posted ledger entries.',
      sections: [
        { heading: 'Which report', body: 'The trial balance lists every account with debits, credits and balance and should net to zero. The income statement is revenue less expenses for a period. The balance sheet shows assets, liabilities and equity on one date, where assets equal liabilities plus equity.' },
        { heading: 'Scope', body: 'Only posted entries count; void entries, pending bank lines and unposted records are excluded. Mirrored stock and vendor balances appear only if they were posted.' }
      ],
      tips: ['Equal totals prove the arithmetic, not that each entry went to the right account.', 'Export CSV from each report for your accountant.']
    ),
    'bank_reconciliation' => Guide.new(
      key: 'bank_reconciliation', title: 'Bank reconciliation',
      summary: 'Match each bank statement line to a ledger entry and explain the difference between statement net and ledger net.',
      sections: [
        { heading: 'Matching', body: 'Rupert suggests a ledger entry for each line by amount and date within the chosen window. Confirming records the link only; no amounts change and a match can be cleared. Possible duplicates can be ignored so they drop out of reconciliation.' },
        { heading: 'The difference', body: 'Statement net (in + out) minus ledger net for the Cash and Checking accounts over the same dates. Card sales post to Cash on receipt and settle later, so timing differences are normal and need explaining, not forcing.' }
      ],
      tips: ['Record bank withdrawals as expenses on Bank statements first, then reconcile here.', 'Widen the match window for slow-settling deposits.']
    ),
    'ledger_export' => Guide.new(
      key: 'ledger_export', title: 'Export ledger',
      summary: 'Download posted journal entries for your accountant or accounting software.',
      sections: [
        { heading: 'Formats', body: 'QuickBooks IIF imports as a general journal. The CSV lists debits and credits per line for Xero, Wave, Sage and similar tools.' },
        { heading: 'Scope', body: 'Only posted entries in the chosen dates are exported; void entries are excluded.' }
      ],
      tips: ['Lock the period before exporting so the file matches what stays on record.']
    ),
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
      key: 'inventory', title: 'Inventory',
      summary: 'Stock, holds and inventory work queues by exact source, item and location.',
      sections: [
        { heading: 'Review stock', body: 'Browse mirrored stock pools and native source freshness. Open Shopify / C-Trax comparison for physical-reference evidence; independent platform quantities are never added together.' },
        { heading: 'Move and allocate', body: 'Transfers reserve the native item at its source, record dispatch and receive full or partial deliveries. Backorders record demand first and allocate when stock is available.' },
        { heading: 'Count and receive', body: 'Prepare counts, review exceptions, receive purchase orders and inspect material lots. Dispatch, receipt and fulfilled backorders require confirmation of the source adjustment and a newer stock read.' }
      ],
      tips: ['Local reservations share capacity with warehouse checkout. Waiting backorders and incoming stock do not increase available-to-promise.', 'These workflows record local execution and operator confirmations. Source stock adjustments remain a separate action in the source platform.']
    ),
    'stock_comparison' => Guide.new(
      key: 'stock_comparison', title: 'Stock comparison',
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
        { heading: "What you're seeing", body: 'A chronological log of business actions: staff member changes, permission edits, and other write operations with the actor and the record they touched.' }
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
        'Add every staff email domain to Google sign-in; new people on an allowed domain get a staff account automatically.',
        'Environment secrets (Square/Shopify tokens) live in the .env card and are encrypted at rest.'
      ]
    ),
    'employees' => Guide.new(
      key: 'employees', title: 'Staff',
      summary: 'Your team directory — who works where, linked to their login accounts.',
      sections: [
        { heading: "What you're seeing", body: 'Every staff member with their role/position and, where set, the login account they use to sign in. Roles drive what each person can see and do.' }
      ],
      tips: [
        'Link a staff member to a login account so their work (timesheets, sales) is attributed to them.',
        'Manage what they can access on the Permissions screen, not by editing the role matrix directly.'
      ]
    ),
    'timesheets' => Guide.new(
      key: 'timesheets', title: 'Timesheets',
      summary: 'Clock-in tracking for the team — time worked per staff member and shift.',
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
        { heading: "What you're seeing", body: 'The login accounts (which pair with staff) and their roles: super_admin, admin, manager, shift_leader, cashier, reader. Shift leaders review timesheets without payroll or account administration. Super admin is platform-wide; everything else is scoped to this store.' }
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
      key: 'finance', title: 'Bookkeeping',
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
        { heading: "What you're seeing", body: "The customer list with relationship counts, search, filters and sorting. Opening a customer shows their activity timeline, follow-ups, notes and order history." }
      ],
      tips: [
        'Search by name, phone, or email — not just order number.',
        'Use the relationship tabs and removable filter chips to narrow the list; Clear all resets it.'
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
        { heading: "What you're seeing", body: 'Departments that staff belong to. They drive reporting and who sees what in the team area.' }
      ],
      tips: [
        'Keep this small and stable; move people between departments, not the departments around them.'
      ]
    ),
    'positions' => Guide.new(
      key: 'positions', title: 'Positions',
      summary: 'The roles people fill — cashier, manager, etc. — independent of login permissions.',
      sections: [
        { heading: "What you're seeing", body: 'Position titles you can assign to staff. Positions describe the job; login permissions control system access.' }
      ],
      tips: [
        'Assign a position to every staff member so the directory and reports read cleanly.'
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
    # Most specific prefixes first: the list is matched in order with start_with?.
    ['/books_check', 'books_check'],
    ['/books/locks', 'period_locks'],
    ['/books', 'books_desk'],
    ['/bookkeeping', 'bookkeeping'],
    ['/approve_books', 'book_approvals'],
    ['/bank_statements', 'bank_statements'],
    ['/snapshot', 'business_snapshot'],
    ['/money_reconciliations', 'source_reports'],
    ['/financial_close', 'financial_close'],
    ['/cash_forecast', 'cash_forecast'],
    ['/reconciliation_follow_ups/overview', 'reconciliation_overview'],
    ['/reconciliation_follow_ups', 'reconciliation_follow_ups'],
    ['/reconciliation_documents', 'reconciliation_documents'],
    ['/retention_drive', 'retention_drive'],
    ['/daily_reconciliations', 'daily_reconciliation'],
    ['/reports/register_summary', 'register_summary'],
    ['/finance/accounts', 'finance_accounts'],
    ['/finance/chart_of_accounts', 'chart_of_accounts'],
    ['/finance/expenses', 'expenses'],
    ['/finance/vendor_payments', 'payments'],
    ['/finance/journal_entries', 'journal_entries'],
    ['/finance/reports', 'finance_reports'],
    ['/finance/bank_reconciliation', 'bank_reconciliation'],
    ['/finance/ledger_export', 'ledger_export'],
    ['/purchasing/vendors', 'vendors'],
    ['/purchasing/purchase_orders', 'purchase_orders'],
    ['/stock_requests', 'stock_requests'],
    ['/stock_reservations', 'stock_reservations'],
    ['/bulk_materials', 'bulk_materials'],
    ['/bulk_recipes', 'bulk_recipes'],
    ['/bulk_consumptions', 'bulk_consumptions'],
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
    ['/stock_comparison', 'stock_comparison'],
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
