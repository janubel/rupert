# frozen_string_literal: true

# One vocabulary and lesson source for contextual help and the learning centre.
#
# A lesson has:
#   key, title, minutes, permission, paths, terms, summary, steps
#   question/choices/answer/explanation   the first knowledge check (kept for older callers)
#   questions: [{ prompt:, choices:, answer:, explanation: }]   further checks (optional)
#   mistakes: [...]                        common mistakes to avoid (optional)
#   practice: 'variance' | 'change' | 'average' | 'cover'   an interactive calculator (optional)
#   destination, action                    the real tool this lesson prepares you for
class LearningCatalog
  TERMS = {
    'source' => ['Source',
                 'The system a record came from, such as Shopify or C-Trax. Check the source and date before comparing figures.'],
    'freshness' => ['Last pulled',
                    'When Rupert last successfully read this source. A recent pull does not prove the source contains every expected record.'],
    'sales_total' => ['Recorded sales total',
                      'Sales stored in Rupert for the selected dates and channels. This is not your bank balance. Check source coverage, refunds, taxes and tips in the report before using the figure.'],
    'mirror' => ['Mirror quantity',
                 'The quantity last read from a source. It may represent available units rather than physical on-hand stock. Unknown stock is different from zero.'],
    'sku' => ['SKU',
              'A product code used to identify a variant. Codes can be missing or reused; check the native item and location before matching stock.'],
    'shared_stock' => ['Shared stock',
                       'Two systems can describe the same physical units. Shopify and C-Trax quantities must not be added together as separate stock.'],
    'reconciliation' => ['Reconciliation',
                         'Compare records for the same dates, currency and location, then explain differences with evidence. A payment report, sale and bank deposit describe different stages.'],
    'snapshot' => ['Snapshot',
                   'A saved view of data at a particular time. Later changes can make an earlier review out of date.'],
    'tender' => ['Tender',
                 'How a customer pays, such as cash or card. Check the receipt and payment status before collecting again.'],
    'period_lock' => ['Period lock',
                      'A control that prevents ledger changes dated inside a locked period until an authorized person reopens it.'],
    'timesheet' => ['Timesheet',
                    'A record of hours for a pay period. Review punches and corrections before submitting it for approval.'],
    'kpi' => ['KPI',
              'A measure used to track a goal. Check its unit, reporting period and target before judging progress.'],
    'on_hand' => ['On-hand stock', 'Physical units held at a location, as reported by that source. Some of those units may already be committed to orders.'],
    'available' => ['Available stock', 'Units the source reports as available to sell. Read the source’s definition; this differs from physical on-hand stock.'],
    'committed' => ['Committed stock', 'Units assigned to existing orders. They can still be physically present while no longer being available to sell.'],
    'hold' => ['Local hold', 'A reservation in Rupert for one native item and location. It reduces Rupert’s advisory availability but does not reserve units in the source platform.'],
    'variance' => ['Count variance', 'Counted units minus the captured comparison quantity. A count of 8 against a comparison of 10 gives −2. Unknown comparison stock has no numerical variance.'],
    'gross' => ['Order gross', 'The amount recorded as gross by the order source. Read the report’s inclusion rules for tax, discounts, shipping and refunds before comparing sources.'],
    'refund' => ['Refund', 'Money returned against an earlier payment. Recorded-sales summaries are before refunds unless the report explicitly says otherwise.'],
    'deposit' => ['Deposit', 'Money funded to a bank account by a processor. Fees, refunds and timing can make it differ from sales recorded on the same day.'],
    'average_sale' => ['Average sale', 'Recorded sales divided by the number of included sales, for the same date, currency and source selection. No included sales means the average is unknown, shown as a dash.'],
    'subtotal' => ['Checkout subtotal', 'The cart’s item amount before the separately displayed tax and tip. Use the checked cart and its receipt as the final amounts.'],
    'change' => ['Cash change', 'Cash received minus the amount due. If the total is $43.16 and the customer hands over $50, change is $6.84.'],
    'estimated_pay' => ['Estimated gross pay', 'An estimate before deductions, based on the recorded hours and pay information available here. It is not a payslip or a confirmed take-home amount.'],
    'draft' => ['Draft', 'Work saved for you to review and change before submission. Saving a draft does not mean it has been approved or carried out.'],
    'sync' => ['Sync / source pull', 'A read of source records into Rupert’s local mirror. Saving credentials is a separate step and does not prove that a pull succeeded.'],
    'follow_up' => ['Follow-up', 'An unresolved task with an owner, next step and due date. Closing a day’s evidence package does not automatically close its follow-ups.'],
    'promise' => ['Available to promise', 'Rupert’s advisory capacity for one source item at one location: the lower usable mirror quantity or mirror available, minus local and warehouse holds, never below zero. Missing or invalid evidence can give zero capacity without proving there is no physical stock. Incoming transfers and waiting demand do not increase it.'],
    'assignee' => ['Task assignee', 'The person responsible for a task. A project owner and task assignee are separate choices; employees see the tasks assigned to their own account.'],
    'blocked' => ['Blocked task', 'Work that cannot continue until a problem is resolved. Mark it blocked and add a note explaining what you need.'],
    'native_id' => ['Source item ID / native ID', 'The item or variant identifier assigned by its original system. Use the source, item ID and location together; a reused SKU is not enough to prove two records are the same item.'],
    'pool' => ['Stock pool', 'One exact source item at one exact location. A hold or allocation applies to that pool, not to every product sharing its SKU.'],
    'journal' => ['Canonical order journal', 'Orders stored in Rupert’s common order format. Native C-Trax receipts stay in daily close and can contribute to the sales summary without appearing in this journal.'],
    'business_date' => ['Business date', 'The operating day selected for a report. Check the displayed time zone and source coverage when comparing it with another system’s day.'],
    'days_of_cover' => ['Days of cover', 'Roughly how long current stock lasts at the recent sales pace: units on hand across locations divided by average units sold per day over the last 30 days. No recent sales means cover cannot be estimated.'],
    'sales_pace' => ['Sales pace', 'Units sold over a recent window, such as 14 or 30 days, across every channel. Pace is a trend, not a promise; seasonal items and one-off orders distort it.'],
    'suggested_reorder' => ['Suggested reorder', 'Enough units to cover about 30 days at the recent sales pace, minus what is on hand, never below zero. Advice only: nothing is ordered or written to a platform.'],
    'stock_alert' => ['Stock alert', 'A flag raised when mirrored stock falls to or below a threshold. Resolving or ignoring an alert records your decision; it does not change stock anywhere.'],
    'role' => ['Role', 'A named bundle of permissions assigned to an account, such as cashier or manager. The role decides which areas and tools appear and which actions are allowed.'],
    'permission' => ['Permission', 'A single allowed action, written as area.verb such as sales.read or inventory.write. Pages and buttons appear only when the account holds the permission, and the server checks it again on every request.'],
    'override' => ['Permission override', 'A per-person exception that narrows or widens the role’s default permissions. Overrides cannot promote someone to administrator or expand the fixed staff boundary.'],
    'lead' => ['Lead', 'A customer record for someone who has not yet bought. Convert a lead when a sale is recorded; keep the history so the relationship stays visible.'],
    'lifetime_value' => ['Lifetime value', 'The recorded sales attributed to one customer across every connected source. It counts stored orders only, so missing imports lower it.'],
    'customer_profile' => ['Customer profile', 'One person as Rupert knows them, combining profiles from several sources. Check the source and date on each detail before relying on a phone number or address.'],
    'punch' => ['Punch', 'One clock-in or clock-out time recorded by a person. Punches build shifts; a timesheet summarises shifts for a pay period.'],
    'correction' => ['Time correction', 'A request to change a recorded punch or shift, with a reason. A reviewer approves or declines it; the original record is kept for the audit trail.'],
    'review_queue' => ['Review queue', 'Items waiting for a decision, such as submitted timesheets or receipts. Approving records the decision; returning sends the item back with a note.'],
    'receipt' => ['Purchase receipt', 'A photo or file of an original receipt with its date, amount and purpose. Submission sends it for review; approval does not pay anyone by itself.'],
    'date_window' => ['Date window', 'The range of days a report covers, such as the last 30 days or a custom start and end. Compare reports only when their windows, time zones and sources match.'],
    'profit_loss' => ['Profit and loss', 'Revenue less expenses for a period, built from recorded sales and recorded expenses. Missing receipts or imports make it look better than it is.'],
    'threshold' => ['Alert threshold', 'The quantity at or below which a stock alert is raised for an item. Thresholds are advice settings; they never change stock.'],
    'path' => ['Learning path', 'A short sequence of lessons suggested for the work you do. Choosing a path changes only what Rupert recommends to you, never your permissions.'],
    'tour' => ['Page tour', 'A short walk through the real elements on a page. Tours never start by themselves; start one from the help bar or the welcome card whenever you like.'],
    # Stock: counts, movements, holds and bulk material
    'counted' => ['Counted quantity', 'The whole units a person physically counted and typed or scanned onto the sheet. It is an observation at one time; it does not change Shopify, Square or C-Trax stock.'],
    'comparison_quantity' => ['Mirrored comparison quantity', 'The source quantity Rupert froze for this item and location when the sheet was submitted. Approving the sheet records the count beside it; nothing is written back to the source.'],
    'transfer' => ['Stock transfer', 'A request to move units of one native item from a source location to a destination. Rupert records each step you confirm; the stock adjustment itself is made in the source platform by a person.'],
    'backorder' => ['Backorder', 'Recorded demand for an item at a fulfillment location that is not yet allocated or fulfilled. Waiting demand holds no stock until someone allocates it.'],
    'allocation' => ['Allocated stock', 'Units set aside in Rupert for a transfer or backorder, which lowers advisory availability for that pool. Allocation does not reserve or move units in Shopify, Square or C-Trax.'],
    'received_quantity' => ['Received / fulfilled quantity', 'Units confirmed as arrived or handed over so far, out of the quantity requested. A partial receipt leaves the rest outstanding until a later confirmation.'],
    'lot' => ['Bulk lot', 'One receipt of a bulk material tracked under its own code and balance. Consumption is recorded against a chosen lot; its ledger is append-only.'],
    'lot_balance' => ['Remaining balance', 'Received weight less recorded consumption for a lot or material, stored as whole milligrams. It reflects entries made in Rupert, not a scale reading.'],
    'recipe' => ['Bulk recipe', 'Grams of one raw material used per sold unit of an exact Shopify variant. Each definition is a new immutable version with an effective time; a reused SKU never selects a recipe.'],
    'material_use' => ['Material-use receipt', 'A record that one imported sale line consumed material from one lot using one recipe version. Each sale line can deduct once, and refunds never return material automatically.'],
    'movement' => ['Inventory movement', 'A recorded change in a mirrored quantity between syncs or an adjustment event. A movement describes what the source reported, not who sold or counted the units.'],
    'stock_value' => ['Stock value at retail', 'Mirrored on-hand quantity multiplied by the current price for every variant with both values. It is a selling-price estimate, not cost of goods, and excludes variants with unknown quantity or price.'],
    'cash_variance' => ['Register cash variance', 'Counted cash at register close minus the cash the session expected. A positive figure means more cash than expected; the total adds every closed session that recorded a variance.'],
    # Purchasing
    'po_total' => ['Ordered value', 'Quantity multiplied by unit cost for every line on the purchase order. It is what was ordered, not what has been invoiced or paid.'],
    'po_pending' => ['Ordered, not received', 'Ordered value minus the value of units received so far. It is a delivery gap, not an invoice balance; what is actually owed to a vendor is shown on the Accounts page.'],
    'unit_cost' => ['Unit cost', 'The price agreed with the vendor for one unit on this order line. Line total is quantity multiplied by unit cost.'],
    'open_po' => ['Open purchase order', 'An order still in draft or placed with the vendor but not yet received or cancelled. Received and cancelled orders are closed.'],
    'payment_terms' => ['Payment terms', 'The vendor’s agreed window for paying an invoice, such as Net 30. Recording terms does not schedule or send a payment.'],
    # Money: sales and register reports
    'net_revenue' => ['Net revenue', 'Gross revenue from paid and fulfilled orders minus refunds recorded against orders in the window. Tax is not subtracted, and refunded orders with no recorded refund amount leave this figure overstated.'],
    'tax_collected' => ['Tax collected', 'Sales tax recorded on the included orders by their source. Rupert shows the stored amount; it does not calculate or file tax.'],
    'revenue_per_day' => ['Revenue per day', 'Daily revenue totals in the window added together and divided by the number of days shown. Days with no orders count as zero.'],
    'eligible_orders' => ['Eligible orders', 'Paid, fulfilled or refunded orders whose stored order date falls on the selected business day. Placed, cancelled and unsettled orders are excluded.'],
    'net_tender' => ['Tenders less refunds', 'Recorded tender amounts received minus recorded refunds for the same tender type, source, location and currency. An accounting comparison, not settled cash or a bank deposit; any unknown amount makes the result Unavailable.'],
    'payment_coverage' => ['Payment coverage', 'Whether imported completed payments cover an order total: missing means none, incomplete means less, overcovered means more. It diagnoses imported records, not the money actually collected.'],
    'unavailable' => ['Unavailable amount', 'A figure the source did not provide or Rupert could not compare. It is shown as Unavailable or Unknown on purpose, because treating it as zero would hide a gap.'],
    'evidence_basis' => ['Evidence basis', 'Where a row’s amount came from: imported orders, gateway payment records, processor deposit reports or an uploaded source report. Rows with different bases can describe the same money and are never added together.'],
    'control' => ['Register control report', 'A source report, such as a register Z-report or processor summary, attached for one source, currency, location and day. Rupert compares its totals with imported records; a missing control means the day cannot be fully checked.'],
    # Money: bank, ledger and statements
    'statement_balance' => ['Statement balance', 'The closing balance printed on the most recent retained bank statement. Rupert has no live bank connection, so this is historical and only as current as that statement.'],
    'net_cash_movement' => ['Net cash movement', 'Statement credits (money in) minus statement debits (money out) for the selected month and account, including transfers. It is not profit and not a reconciled balance.'],
    'decision' => ['Line decision', 'Your choice of what a bank statement line was: an expense category, a vendor payment, or excluded because it is not a business expense. Nothing is recorded until you save, and each saved decision keeps your name and time.'],
    'matched_line' => ['Matched statement line', 'A bank statement line you confirmed belongs to one ledger entry. Matching records the link only; no amounts change and the match can be cleared later.'],
    'statement_net' => ['Statement net', 'Deposits (in) plus withdrawals (out, negative) on the statement lines for the chosen account and dates. Ignored lines are left out.'],
    'ledger_net' => ['Ledger net', 'Net movement posted to the Cash and Checking accounts in the general ledger for the same dates. Card sales post to Cash on receipt and settle to the bank later, so timing differences are normal.'],
    'bank_difference' => ['Statement minus ledger', 'Statement net minus ledger net for the same account and dates. Zero means the two agree in total; a non-zero figure needs explaining with unmatched lines, timing or missing entries, and nothing is adjusted automatically.'],
    'debit_credit' => ['Debits and credits', 'The two sides of every ledger entry; within one entry they must be equal. A debit increases assets and expenses, a credit increases liabilities, equity and revenue.'],
    'normal_balance' => ['Increases with', 'The side that makes an account grow: assets and expenses increase with debits, liabilities, equity and revenue with credits. It decides whether a balance reads as positive on reports.'],
    'account_balance' => ['Account balance', 'Debits minus credits posted to the account in the period, shown from the account’s normal side. Void entries are excluded.'],
    'trial_balance' => ['Trial balance', 'Every account with activity in the period, with the total debited, credited and the balance. If the books are in order, total debits equal total credits; equal totals do not prove each entry is correct.'],
    'net_income' => ['Net income', 'Total revenue less total expenses posted to the ledger for the period. A negative figure is a net loss. It is built from posted entries only, so unrecorded expenses make it look better than it is.'],
    'equity' => ['Equity', 'What the business is worth to its owner on paper: assets minus liabilities. On the balance sheet, assets must equal liabilities plus equity.'],
    'current_period_earnings' => ['Current period earnings', 'Net income since the start of the ledger that has not yet been closed into retained earnings. It sits in equity so the balance sheet balances.'],
    'void_entry' => ['Void entry', 'A ledger entry kept for the audit trail but excluded from every report and export. Entries are voided automatically when the expense or payment they came from is removed.'],
    'reversal' => ['Reversing entry', 'A new entry that swaps every debit and credit of an earlier one so their net effect is zero. Posted entries are never edited; reversal is how a mistake is corrected.'],
    'accounts_payable' => ['Vendor balance due', 'Value of goods received from a vendor less payments recorded to that vendor in Rupert. It is a local record, not the vendor’s invoice or your bank balance.'],
    'vendor_credit' => ['Vendor credit / prepayment', 'Recorded payments to a vendor that exceed the value of goods received from them. It is shown separately and never reduces another vendor’s balance.'],
    'accounts_receivable' => ['Customer receivable', 'Paid or fulfilled order gross less completed payments imported for the same customer and currency. A missing order amount keeps the balance Unknown; unimported payments make it look larger than it is.'],
    'expense' => ['Recorded expense', 'A business payment that already happened, entered with its date, payee, category and amount. Recording it posts a ledger entry; no money is transferred.'],
    'vendor_payment' => ['Vendor payment', 'A payment already made against a vendor’s purchase orders, recorded to lower the local balance due. Recording it does not send money.'],
    # Money: close, review and approval
    'close_check' => ['Close check', 'A condition that must be resolved or documented before a business date can be closed completely, such as a missing register report or an open difference. Counts describe checks and may overlap.'],
    'close_package' => ['Close package', 'A retained, checksum-verified version of a day’s evidence, review, checklist and outstanding work. Retaining it does not close follow-ups, post a ledger entry or send anything.'],
    'original_document' => ['Retained original', 'An uploaded source file kept unchanged and encrypted in Rupert, with each correction stored as a new version. Originals are never deleted automatically.'],
    'fingerprint' => ['Evidence fingerprint', 'A digest of the records a review, approval or lock was based on. If any of those records change later, the review shows as changed and needs a fresh look.'],
    'books_check' => ['Books health check', 'A read-only test that looks for records that disagree with each other, graded as fix, watch or passing. Passing checks do not certify a bank reconciliation.'],
    'opening_cash' => ['Opening cash', 'The bank cash you enter as of the close date, in one currency. It is your assumption or an entered bank balance, never a figure Rupert reads from a bank.'],
    'closing_cash' => ['Projected closing cash', 'Opening cash plus expected bank receipts minus expected payments for each week in the scenario. A manual plan, not a prediction or verified balance.'],
    'reserve' => ['Minimum reserve', 'The cash level you want to stay above. Weeks whose projected closing falls below it are highlighted; leaving it blank checks for negative cash only.'],
    # People: pay
    'gross_pay' => ['Gross pay', 'Pay before deductions: hours multiplied by the pay rate, or the salary share for the period, plus any manual payslip amount. Finalizing locks it; it is not a payslip sent to anyone.'],
    'deductions' => ['Deductions', 'Amounts withheld from gross pay. Unless entered by hand, Rupert fills a flat 15% estimate when a run is finalized, which is a placeholder and not a tax calculation.'],
    'net_pay' => ['Net to pay', 'Gross pay minus deductions for each payslip, added across the run. Marking a run paid records that decision; Rupert does not move money.']
  }.freeze

  LESSONS = [
    { key: 'start', title: 'Find your way around', minutes: 2, permission: nil, paths: [], terms: %w[source freshness tour path],
      summary: 'Know where to go and what to check first.',
      steps: ['Use your workspace links to open everyday tools. Your account determines which tools you can use.', 'On reports, start with the date, source and last successful pull. Missing imports can look like no activity.', 'Open How this page works for guidance, or press ? for help. Learn Rupert & definitions is always available from your account menu or the staff footer.'],
      question: 'A page shows no sales today. What should you check first?', choices: ['Assume the store made no sales', 'Check the date and source coverage', 'Add a sale to make the total look right'], answer: 1,
      explanation: 'A zero can mean no imported activity. Check the selected date and source coverage before drawing a conclusion.',
      questions: [{ prompt: 'You see a word you don’t recognise next to a number. What is the quickest way to find out what it means?', choices: ['Guess from the number', 'Tap the ? beside it or press ? to search definitions', 'Ask a colleague to log in as you'], answer: 1, explanation: 'Definitions sit beside the work and in the help panel. Never share or use another person’s account.' }],
      mistakes: ['Treating an empty report as proof that nothing happened.', 'Comparing two reports with different dates or sources.'],
      destination: '/learning', action: 'Choose your next lesson' },
    { key: 'setup', title: 'Get your workspace ready', minutes: 3, permission: 'settings.read', paths: ['/onboarding', '/connections', '/pos_connections', '/settings'], terms: %w[sync source freshness],
      summary: 'Connect the sources you use, verify a read, then check your first working day.',
      steps: ['Open Credentials & sync and review the services your store uses. Ask an administrator to save credentials if your account has read-only access.', 'Saving details is the first step. Have an authorized operator run the relevant source pull, then check the successful read time and any reported errors.', 'Open a familiar business date and compare a known sale or stock observation with its source. Confirm staff can find their own workspace and get help before relying on a total.'],
      question: 'A connection says details are saved, but no successful read is recorded. Is its data ready?', choices: ['Yes, saving details proves the connection works', 'Not yet; verify a successful source read and the expected records', 'Yes, an empty report confirms there was no activity'], answer: 1,
      explanation: 'Saved credentials and successfully imported records are separate milestones.',
      mistakes: ['Pasting credentials into a chat or document instead of the encrypted settings.', 'Announcing “we’re live” before a known sale appears in Rupert.'],
      destination: '/connections', action: 'Review credentials & sync' },
    { key: 'sync', title: 'Keep sources fresh', minutes: 2, permission: 'sync.read', paths: ['/syncs'], terms: %w[sync freshness source snapshot],
      summary: 'Read sync history, spot a stale source and know what a failure means.',
      steps: ['Open Sync. Each row is one pull from one source with a start time, a finish time and a status.', 'A green status means the read finished without an error. It does not prove every expected record exists; check a familiar order or item.', 'A failed or long-running pull is a reason to check credentials and the provider, not to type figures in by hand. Syncs are read-only mirrors and never write to a platform.'],
      question: 'The last Shopify pull failed two hours ago. Today’s sales show $0. What is true?', choices: ['The store made no sales', 'Today’s figure may be incomplete until a pull succeeds', 'The sync changed Shopify stock'], answer: 1,
      explanation: 'A failed pull leaves the mirror stale. Fix the read first, then judge the number.',
      questions: [{ prompt: 'What does a sync write to Shopify or Square?', choices: ['Nothing; it only reads into Rupert', 'Updated quantities', 'New SKUs'], answer: 0, explanation: 'The sync loop is a read-only mirror. Outbound writes happen only through explicit, owner-approved flows.' }],
      mistakes: ['Reading a recent pull time as proof the data is complete.', 'Running the same sync repeatedly during a provider outage.'],
      destination: '/syncs', action: 'Open sync history' },
    { key: 'access', title: 'Give the right access', minutes: 3, permission: 'users.read', paths: ['/users', '/permissions'], terms: %w[role permission override],
      summary: 'Choose a role, add exceptions sparingly and know the boundaries that cannot move.',
      steps: ['Add an account with the person’s own email. Pick the role that matches their everyday work; the role decides which areas appear.', 'Use the Permissions matrix to see what each role can read and write. Per-person overrides are for exceptions, and they should be rare.', 'Staff accounts stay inside a fixed boundary: POS, their own time and assigned tasks. Administrator and platform roles cannot be granted through checkboxes. Deactivate accounts when people leave.'],
      question: 'A cashier needs to see yesterday’s sales report once. What is the sound approach?', choices: ['Share your login', 'Grant a narrow, reviewable override or run the report for them', 'Make them an administrator'], answer: 1,
      explanation: 'Never share accounts. Grant the smallest reviewable access, or do the task yourself.',
      questions: [{ prompt: 'Can a permission override make a staff account see payroll?', choices: ['Yes, any box can be ticked', 'No, the staff boundary is fixed on the server', 'Only on weekends'], answer: 1, explanation: 'Role-only boundaries are enforced server-side and cannot be delegated through ordinary permission checkboxes.' }],
      mistakes: ['Promoting someone to administrator to solve one missing permission.', 'Leaving accounts active after a person leaves.'],
      destination: '/users', action: 'Open accounts' },
    { key: 'checkout', title: 'Serve a customer at the register', minutes: 3, permission: 'pos', paths: ['/ctrax_pos', '/pos_checkouts'], terms: %w[tender subtotal change freshness],
      summary: 'Check the cart, collect payment and verify the receipt.',
      steps: ['Check the store and stock-read timestamp, then find products and review quantities and prices in the cart.', 'Let the customer confirm their tip on the private customer screen. Review the final total and choose the correct tender.', 'Check the resulting receipt and payment status. Resume an unfinished checkout before trying a new payment; ask your manager when the status is unclear.'],
      question: 'A checkout appears unfinished after a payment attempt. What next?', choices: ['Immediately collect payment again', 'Check the receipt and resume the existing checkout', 'Create a second cart with the same items'], answer: 1,
      explanation: 'Check the existing receipt and payment state before collecting again to avoid a duplicate payment.',
      questions: [{ prompt: 'The total due is $43.16 and the customer hands you $50. What is the change?', choices: ['$6.84', '$7.84', '$50.00'], answer: 0, explanation: 'Change is cash received minus the amount due: $50.00 − $43.16 = $6.84.' }],
      mistakes: ['Collecting a second payment because the screen looked stuck.', 'Reading cash received as the sale amount.'],
      practice: 'change',
      destination: '/ctrax_pos', action: 'Open retail POS' },
    { key: 'customers', title: 'Keep customer records useful', minutes: 2, permission: 'customers.read', paths: ['/customers'], terms: %w[customer_profile lead lifetime_value follow_up source],
      summary: 'Find a person, read their history and record the next step.',
      steps: ['Search by name, email or phone. One person can have profiles from several sources; the merged profile keeps every source identity.', 'Read lifetime value as recorded sales only. A missing import or a cash sale with no record lowers it.', 'Record interactions and follow-ups with an owner and date, so the next person knows what was promised.'],
      question: 'A customer’s lifetime value looks too low. What is the first thing to check?', choices: ['Edit the value by hand', 'Whether their sales were imported and matched to this profile', 'Delete duplicate profiles immediately'], answer: 1,
      explanation: 'Lifetime value is a sum of stored orders. Check coverage and matching before changing anything.',
      mistakes: ['Deleting a duplicate profile without checking which one holds the history.', 'Saving private notes a customer would not expect you to keep.'],
      destination: '/customers', action: 'Open Customer CRM' },
    { key: 'staff', title: 'Your hours and receipts', minutes: 2, permission: nil, paths: ['/employee', '/time_clock', '/people/timesheets', '/receipts'], terms: %w[timesheet estimated_pay draft punch correction receipt],
      summary: 'Record your work and send accurate information for review.',
      steps: ['Use My time for your schedule, hours and time off. Check that you are signed in as yourself.', 'Review your punches and request a correction when something is wrong. Check the dates and hours before submitting your timesheet.', 'Attach a clear original receipt and check its date, amount and purpose before submitting it. Submission sends it for review; it does not mean payment has been approved.'],
      question: 'Your recorded hours are wrong. What should you do?', choices: ['Submit them anyway', 'Request a correction and review the result', 'Use another person’s account'], answer: 1,
      explanation: 'Correct and review your own hours before submission.',
      questions: [{ prompt: 'Your week shows 8 hours at $20 per hour but you worked 7.5. What is the corrected estimate?', choices: ['$160.00', '$150.00', '$170.00'], answer: 1, explanation: '7.5 hours × $20 = $150.00. Estimates are before deductions and are not a payslip.' }],
      mistakes: ['Submitting a timesheet before checking every day.', 'Photographing a receipt that is cropped or unreadable.'],
      destination: '/employee', action: 'Open My time' },
    { key: 'stock', title: 'Understand stock before acting', minutes: 3, permission: 'inventory.read', paths: ['/inventory', '/stock_comparison', '/reconcile', '/stock_reservations', '/stock_requests'], terms: %w[mirror sku native_id shared_stock on_hand available committed hold pool],
      summary: 'Read quantities, identify items and avoid counting shared stock twice.',
      steps: ['Identify the native item, variant and location. A SKU alone may not uniquely identify a product.', 'Read the quantity label and timestamp. Mirror quantity is not always physical on-hand stock; missing observations remain unknown.', 'Shopify and C-Trax mostly observe shared physical stock. Compare their observations without adding them. Local counts and holds do not automatically update a provider.'],
      question: 'Shopify and C-Trax each show 10 units of the same shared physical stock. How many units can you conclude are present?', choices: ['20 units', '100 units', 'Do not sum them; verify the physical reference'], answer: 2,
      explanation: 'Both systems can be observing the same units. Use the physical reference and fresh evidence.',
      questions: [{ prompt: 'A source reports 10 on hand with 3 committed to orders. How many are available to sell?', choices: ['13', '7', '10'], answer: 1, explanation: 'On hand minus committed: 10 − 3 = 7. Read the source’s own fields; on hand and available describe different things.' }],
      mistakes: ['Adding Shopify and register quantities together.', 'Reading an unknown quantity as zero.'],
      destination: '/inventory', action: 'Open inventory' },
    { key: 'counts', title: 'Count stock and explain differences', minutes: 3, permission: 'inventory.read', paths: ['/inventory_counts', '/inventory_exceptions'], terms: %w[variance draft mirror],
      summary: 'Record what is physically present and keep the comparison meaningful.',
      steps: ['Choose the location being counted. Identify the exact variants and record the physical quantities, including a real zero when no units are present.', 'Review the worksheet before submitting. The comparison is captured on submission; inspect the quantity label, source and any unknown or ambiguous item matches.', 'Review differences with the approver. Approval records the count locally; it does not change mirrored or platform stock. Any source adjustment is a separate authorized task.'],
      question: 'You count 8 units against a captured comparison of 10. What does the variance mean?', choices: ['−2 units compared with the captured quantity', '+2 units compared with the captured quantity', 'The source was automatically updated to 8'], answer: 0,
      explanation: 'Variance is counted minus comparison: 8 − 10 = −2. Recording or approving the worksheet does not push a source adjustment.',
      questions: [{ prompt: 'The comparison quantity for an item is unknown. What is its variance after you count 5?', choices: ['−5', '+5', 'No numerical variance; it stays unknown'], answer: 2, explanation: 'An unknown comparison never becomes a zero. Record the count and flag the item for review.' }],
      mistakes: ['Skipping empty shelves instead of recording a real zero.', 'Expecting approval to fix the platform quantity.'],
      practice: 'variance',
      destination: '/inventory_counts', action: 'Review manual counts' },
    { key: 'alerts', title: 'Turn alerts into restock decisions', minutes: 3, permission: 'alerts.read', paths: ['/alerts'], terms: %w[stock_alert threshold sales_pace days_of_cover suggested_reorder],
      summary: 'Read cover and suggested quantities, then decide with the shelf and supplier in mind.',
      steps: ['Open alerts sort by urgency: fewest days of cover first. Read on-hand per location and the units sold in the last 14 and 30 days.', 'Days of cover is on hand divided by the average daily sales over 30 days. Suggested reorder is 30 days of that pace minus what you hold, never below zero.', 'Decide: resolve when you have acted or the alert is wrong, ignore when the item is discontinued. Both record your decision only; nothing is ordered or written.'],
      question: 'An item has 6 on hand and sold 30 units in the last 30 days. What are its days of cover?', choices: ['About 6 days', 'About 30 days', 'About 180 days'], answer: 0,
      explanation: 'Pace is 30 ÷ 30 = 1 unit per day. Cover is 6 ÷ 1 = 6 days.',
      questions: [{ prompt: 'Same item: what is the suggested reorder?', choices: ['6 units', '24 units', '36 units'], answer: 1, explanation: '30 days × 1 unit per day = 30 units; minus 6 on hand = 24.' },
                  { prompt: 'An item shows “no sales” for cover. What does that mean?', choices: ['Order a lot of it', 'Pace cannot be estimated, so no cover or suggestion is shown', 'It is out of stock'], answer: 1, explanation: 'Without recent sales there is no pace to divide by. Decide from the shelf and the season instead.' }],
      mistakes: ['Ordering the suggested quantity without checking pack sizes and lead times.', 'Resolving alerts in bulk without reading the rows.'],
      practice: 'cover',
      destination: '/alerts', action: 'Open alerts' },
    { key: 'sales', title: 'Make sense of sales totals', minutes: 3, permission: 'sales.read', paths: ['/sales', '/ctrax_days'], terms: %w[sales_total average_sale journal business_date gross refund deposit source freshness],
      summary: 'Understand what a total covers before comparing it.',
      steps: ['Select the business date and channels you intend to review.', 'Read the report’s included amounts and source coverage. Review refunds, taxes and tips separately where indicated.', 'Compare equivalent periods and sources. Processor reports and deposits must not be added to sales as extra revenue.'],
      question: 'Should you add a processor deposit to the sales total?', choices: ['Yes, it is another sale', 'No, it represents a different stage of the money flow', 'Only if it arrived today'], answer: 1,
      explanation: 'Sales and deposits can describe the same money at different stages. Adding them can double count it.',
      questions: [{ prompt: 'Two included sales of $30 and $20. What is the average sale?', choices: ['$50.00', '$25.00', '$10.00'], answer: 1, explanation: 'Recorded sales $50 ÷ 2 included sales = $25.00.' }],
      mistakes: ['Comparing a calendar day in one system with a business day in another.', 'Treating “before refunds” as net revenue.'],
      practice: 'average',
      destination: '/sales', action: 'Open sales' },
    { key: 'reports', title: 'Read reports without being misled', minutes: 3, permission: 'reports.read', paths: ['/reports'], terms: %w[date_window business_date profit_loss gross refund source freshness],
      summary: 'Match windows and sources, then read each figure with its inclusion rule.',
      steps: ['Choose the window: last 7, 30, 90 or 365 days, or exact dates. Every figure and chart on the page follows that window.', 'Sales reports are recorded sales before refunds. Financial reports subtract recorded expenses, so a missing receipt inflates profit.', 'Export CSV when you need to compare elsewhere, and note the window and sources used so the comparison stays honest.'],
      question: 'Profit looks high this month. What should you rule out first?', choices: ['A missing expense import or receipt', 'A bonus', 'Nothing; profit is profit'], answer: 0,
      explanation: 'Profit and loss is built from recorded sales and recorded expenses. Missing expenses make it look better than it is.',
      questions: [{ prompt: 'You compare a 30-day sales report with a bank statement for the calendar month. Why might they differ?', choices: ['Different windows, fees and deposit timing', 'The report is wrong', 'The bank is wrong'], answer: 0, explanation: 'Windows, fees, refunds and funding delays all move money between days. Reconcile matching windows with evidence.' }],
      mistakes: ['Comparing reports with different windows or time zones.', 'Reading a chart without checking which sources it includes.'],
      destination: '/reports', action: 'Open reports' },
    { key: 'books', title: 'Review and close a day', minutes: 4, permission: 'reports.read', paths: ['/books', '/bookkeeping', '/financial_close', '/daily_reconciliations', '/bank_statements', '/finance', '/books_check', '/reconciliation_follow_ups', '/money_reconciliations', '/cash_forecast'], terms: %w[reconciliation snapshot period_lock follow_up],
      summary: 'Work through evidence, differences and follow-ups in order.',
      steps: ['Open Close & review and follow the next unfinished day. Check that expected source reports and originals are present.', 'Compare matching dates, currencies and locations. Document timing, fees and unexplained differences with evidence.', 'Assign unresolved follow-ups, then review the current data. Changed evidence requires a fresh review; a retained close package does not finish open follow-ups.'],
      question: 'Source evidence changed after you reviewed the day. What next?', choices: ['Keep relying on the old review', 'Delete the source evidence', 'Review the updated evidence again'], answer: 2,
      explanation: 'Reviews refer to a particular version of the evidence. Recheck the changed day.',
      questions: [{ prompt: 'Recorded sales are $100 and bank funding is $97. What do you do with the $3?', choices: ['Record a fee to make it match', 'Explain it with evidence or assign a follow-up', 'Ignore it'], answer: 1, explanation: 'Never invent a fee. Verify it in source evidence or track the difference as a follow-up.' }],
      mistakes: ['Inventing an adjustment to force a match.', 'Closing a day while its follow-ups are still open.'],
      destination: '/books', action: 'Open Close & review' },
    { key: 'timesheet_review', title: 'Review hours fairly', minutes: 3, permission: 'timesheet_review', paths: ['/people/timesheets', '/people/punch_history'], terms: %w[timesheet punch correction review_queue estimated_pay],
      summary: 'Approve what the evidence supports, return the rest with a clear note.',
      steps: ['Open Timesheets. Needs review lists submitted weeks oldest first. You cannot approve your own linked hours.', 'Compare each day with punches, schedule and any correction requests. Demo hours are never paid.', 'Approve when the week is right. Return it for correction with a note that says exactly what to fix; the person sees your comment on their home page.'],
      question: 'A submitted week shows 9 hours on a day the schedule and punches show 7. What do you do?', choices: ['Approve it to avoid conflict', 'Return it with a note asking about the extra two hours', 'Edit the hours yourself without telling them'], answer: 1,
      explanation: 'Return with a specific note. The person corrects and resubmits; the audit trail stays intact.',
      questions: [{ prompt: 'Whose timesheet can a reviewer never approve?', choices: ['A new hire’s', 'Their own linked employee’s', 'Anyone’s on a Monday'], answer: 1, explanation: 'A reviewer cannot approve or return their own linked hours. Another reviewer must do it.' }],
      mistakes: ['Approving a week without opening the days.', 'Returning a timesheet with no note.'],
      destination: '/people/timesheets', action: 'Open the review queue' },
    { key: 'receipts_review', title: 'Review purchase receipts', minutes: 2, permission: 'receipts_review', paths: ['/receipts/review'], terms: %w[receipt review_queue draft],
      summary: 'Check the original, the amount and the purpose before approving.',
      steps: ['Open Receipts. Submitted receipts wait in your queue with the original attached.', 'Check the date, total, vendor and purpose against the image. Approve when they match; reject with a reason when they do not.', 'Approval records the decision for bookkeeping. It does not reimburse or pay anyone by itself.'],
      question: 'A receipt image is blurry and the total cannot be read. What do you do?', choices: ['Approve the typed amount', 'Reject with a note asking for a clear original', 'Guess the total'], answer: 1,
      explanation: 'The original is the evidence. Ask for a readable one before approving.',
      mistakes: ['Approving from the typed amount without opening the image.', 'Assuming approval triggers a payment.'],
      destination: '/receipts', action: 'Open receipts' },
    { key: 'tasks', title: 'Find and update your assigned tasks', minutes: 2, permission: 'assigned_tasks', paths: ['/projects/tasks', '/projects/getting-started'], terms: %w[assignee blocked],
      summary: 'Know what is yours, update its status and make blockers visible.',
      steps: ['Open My tasks in the staff navigation, or Tasks in the Work area. Employees see their own assigned tasks; managers can see the work their account permits.', 'Choose Board or List and use the filters to find the task. Start it when work begins, then mark it Done when the outcome is complete.', 'If you cannot continue, mark it Blocked and add a note about the help you need. Ask your manager if work is missing, unassigned or assigned to the wrong person.'],
      question: 'You need a missing document before you can finish a task. What should you do?', choices: ['Mark it Done so it disappears', 'Mark it Blocked and explain what you need', 'Change another person’s assignment'], answer: 1,
      explanation: 'A blocked status and a clear note make the obstacle visible so the right person can help.',
      mistakes: ['Marking a task done because it is annoying.', 'Leaving a blocker unexplained.'],
      destination: '/projects/tasks', action: 'Open tasks' },
    { key: 'work', title: 'Track work and goals', minutes: 2, permission: 'projects.read', paths: ['/projects', '/goals'], terms: %w[kpi assignee],
      summary: 'Give each task a clear outcome and each measure a useful target.',
      steps: ['Open the project and find the task that needs action. Check its owner and due date.', 'Move tasks as the work progresses and record enough detail for the next person.', 'Read each KPI’s unit, period and target together. A number without its definition cannot explain progress.'],
      question: 'What makes a KPI useful?', choices: ['A number with a clear unit, period and target', 'The largest possible number', 'A title alone'], answer: 0,
      explanation: 'The unit, period and target give the measurement meaning.',
      mistakes: ['Creating tasks with no assignee.', 'Reporting a KPI without its period.'],
      destination: '/projects/projects', action: 'Open projects' },
    { key: 'team_chat', title: 'Use team chat and Rupert’s bots', minutes: 3, permission: 'team_chat', paths: ['/chat'], terms: [],
      video: '/videos/team-chat-demo.mp4',
      summary: 'Talk to the team in rooms and direct messages, and ask Rupert’s bots about the business.',
      steps: ['Open Team chat from the chat button in the header (a small window on any page) or System → Team chat for the full view. #admins holds every admin and Rupert; Direct lists each person.',
              'Type @ to mention someone. @rupert asks the main assistant (DeepSeek, cloud, fast); @liquid, @qwen and @ternary are private local models (slower); @all asks every bot and shows their answers side by side.',
              'Hover a message to reply in a thread, react, pin it as the room banner, copy a link to it or edit your own. Paste or drop photos and files into the message box.',
              'Rate bot replies with 👍 or 👎 and add a few words on why. Model scores shows which bot helps most. When a bot proposes a change, nothing happens until someone presses Approve.'],
      question: 'You want to compare how every bot answers the same question. What do you write?', choices: ['@rupert', '@all', '@everyone'], answer: 1,
      explanation: '@all asks @rupert and every local bot, and shows their answers side by side so you can rate each one.',
      mistakes: ['Expecting a bot to change something without an Approve.', 'Pasting passwords or card numbers into chat.'],
      destination: '/chat', action: 'Open team chat' }
  ].freeze

  class << self
    def available(user)
      LESSONS.select { |lesson| permitted?(lesson, user) }
    end

    def find(key)
      LESSONS.find { |lesson| lesson[:key] == key.to_s }
    end

    def permitted?(lesson, user)
      case lesson[:permission]
      when nil then true
      when 'pos' then user.can_use_pos?
      when 'assigned_tasks' then user.employee? || user.can?('projects.read')
      when 'timesheet_review' then user.can_review_timesheets?
      when 'receipts_review' then user.can_review_receipts?
      when 'team_chat' then TeamChat.allowed?(user)
      else user.can?(lesson[:permission])
      end
    end

    def for_path(path, user)
      available(user).select { |lesson| lesson[:paths].any? { |prefix| path_matches?(path, prefix) } }
        .max_by { |lesson| lesson[:paths].select { |prefix| path_matches?(path, prefix) }.map(&:length).max }
    end

    # All knowledge checks for a lesson as an array of hashes, first the legacy
    # single question and then any extras.
    def questions(lesson)
      first = { prompt: lesson[:question], choices: lesson[:choices], answer: lesson[:answer], explanation: lesson[:explanation] }
      [first] + Array(lesson[:questions])
    end

    def search_terms(query)
      query = query.to_s.downcase
      TERMS.select { |_key, term| query.blank? || term.join(' ').downcase.include?(query) }
        .sort_by { |_key, term| term.first.downcase }.to_h
    end

    def search_lessons(lessons, query)
      query = query.to_s.downcase
      lessons.select do |lesson|
        vocabulary = lesson[:terms].flat_map { |term| TERMS.fetch(term) }
        text = [lesson[:title], lesson[:summary], *lesson[:steps], *Array(lesson[:mistakes]), *vocabulary].join(' ')
        query.blank? || text.downcase.include?(query)
      end
    end

    private

    def path_matches?(path, prefix)
      path == prefix || path.start_with?("#{prefix}/")
    end
  end
end
