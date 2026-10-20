# frozen_string_literal: true

# One vocabulary and lesson source for contextual help and the learning centre.
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
    'promise' => ['Available to promise', 'Rupert’s advisory capacity for one source item at one location: the lower usable mirror quantity or mirror available, minus local and warehouse holds, never below zero. Missing or invalid evidence can give zero capacity without proving there is no physical stock. Incoming transfers and waiting demand do not increase it.']
  }.freeze

  LESSONS = [
    { key: 'start', title: 'Find your way around', minutes: 2, permission: nil, paths: [], terms: %w[source freshness],
      summary: 'Know where to go and what to check first.',
      steps: ['Use your workspace links to open everyday tools. Your account determines which tools you can use.', 'On reports, start with the date, source and last successful pull. Missing imports can look like no activity.', 'Open How this page works for guidance. Learn Rupert & definitions is always available from your account menu or the staff footer.'],
      question: 'A page shows no sales today. What should you check first?', choices: ['Assume the store made no sales', 'Check the date and source coverage', 'Add a sale to make the total look right'], answer: 1,
      explanation: 'A zero can mean no imported activity. Check the selected date and source coverage before drawing a conclusion.', destination: '/learning', action: 'Choose your next lesson' },
    { key: 'setup', title: 'Get your workspace ready', minutes: 3, permission: 'settings.read', paths: ['/onboarding', '/connections', '/pos_connections', '/syncs', '/settings'], terms: %w[sync source freshness],
      summary: 'Connect the sources you use, verify a read, then check your first working day.',
      steps: ['Open Credentials & sync and review the services your store uses. Ask an administrator to save credentials if your account has read-only access.', 'Saving details is the first step. Have an authorized operator run the relevant source pull, then check the successful read time and any reported errors.', 'Open a familiar business date and compare a known sale or stock observation with its source. Confirm staff can find their own workspace and get help before relying on a total.'],
      question: 'A connection says details are saved, but no successful read is recorded. Is its data ready?', choices: ['Yes, saving details proves the connection works', 'Not yet; verify a successful source read and the expected records', 'Yes, an empty report confirms there was no activity'], answer: 1,
      explanation: 'Saved credentials and successfully imported records are separate milestones.', destination: '/connections', action: 'Review credentials & sync' },
    { key: 'checkout', title: 'Serve a customer at the register', minutes: 3, permission: 'pos', paths: ['/ctrax_pos', '/pos_checkouts'], terms: %w[tender subtotal change freshness],
      summary: 'Check the cart, collect payment and verify the receipt.',
      steps: ['Check the store and stock-read timestamp, then find products and review quantities and prices in the cart.', 'Let the customer confirm their tip on the private customer screen. Review the final total and choose the correct tender.', 'Check the resulting receipt and payment status. Resume an unfinished checkout before trying a new payment; ask your manager when the status is unclear.'],
      question: 'A checkout appears unfinished after a payment attempt. What next?', choices: ['Immediately collect payment again', 'Check the receipt and resume the existing checkout', 'Create a second cart with the same items'], answer: 1,
      explanation: 'Check the existing receipt and payment state before collecting again to avoid a duplicate payment.', destination: '/ctrax_pos', action: 'Open retail POS' },
    { key: 'staff', title: 'Your hours and receipts', minutes: 2, permission: nil, paths: ['/employee', '/time_clock', '/people/timesheets', '/receipts'], terms: %w[timesheet estimated_pay draft],
      summary: 'Record your work and send accurate information for review.',
      steps: ['Use My time for your schedule, hours and time off. Check that you are signed in as yourself.', 'Review your punches and request a correction when something is wrong. Check the dates and hours before submitting your timesheet.', 'Attach a clear original receipt and check its date, amount and purpose before submitting it. Submission sends it for review; it does not mean payment has been approved.'],
      question: 'Your recorded hours are wrong. What should you do?', choices: ['Submit them anyway', 'Request a correction and review the result', 'Use another person’s account'], answer: 1,
      explanation: 'Correct and review your own hours before submission.', destination: '/employee', action: 'Open My time' },
    { key: 'stock', title: 'Understand stock before acting', minutes: 3, permission: 'inventory.read', paths: ['/inventory', '/stock_comparison', '/reconcile', '/alerts', '/stock_reservations', '/stock_requests'], terms: %w[mirror sku shared_stock on_hand available committed hold],
      summary: 'Read quantities, identify items and avoid counting shared stock twice.',
      steps: ['Identify the native item, variant and location. A SKU alone may not uniquely identify a product.', 'Read the quantity label and timestamp. Mirror quantity is not always physical on-hand stock; missing observations remain unknown.', 'Shopify and C-Trax mostly observe shared physical stock. Compare their observations without adding them. Local counts and holds do not automatically update a provider.'],
      question: 'Shopify and C-Trax each show 10 units of the same shared physical stock. How many units can you conclude are present?', choices: ['20 units', '100 units', 'Do not sum them; verify the physical reference'], answer: 2,
      explanation: 'Both systems can be observing the same units. Use the physical reference and fresh evidence.', destination: '/inventory', action: 'Open inventory' },
    { key: 'counts', title: 'Count stock and explain differences', minutes: 3, permission: 'inventory.read', paths: ['/inventory_counts', '/inventory_exceptions'], terms: %w[variance draft mirror],
      summary: 'Record what is physically present and keep the comparison meaningful.',
      steps: ['Choose the location being counted. Identify the exact variants and record the physical quantities, including a real zero when no units are present.', 'Review the worksheet before submitting. The comparison is captured on submission; inspect the quantity label, source and any unknown or ambiguous item matches.', 'Review differences with the approver. Approval records the count locally; it does not change mirrored or platform stock. Any source adjustment is a separate authorized task.'],
      question: 'You count 8 units against a captured comparison of 10. What does the variance mean?', choices: ['−2 units compared with the captured quantity', '+2 units compared with the captured quantity', 'The source was automatically updated to 8'], answer: 0,
      explanation: 'Variance is counted minus comparison: 8 − 10 = −2. Recording or approving the worksheet does not push a source adjustment.', destination: '/inventory_counts', action: 'Review manual counts' },
    { key: 'sales', title: 'Make sense of sales totals', minutes: 3, permission: 'sales.read', paths: ['/sales', '/reports', '/ctrax_days'], terms: %w[sales_total average_sale gross refund deposit source freshness],
      summary: 'Understand what a total covers before comparing it.',
      steps: ['Select the business date and channels you intend to review.', 'Read the report’s included amounts and source coverage. Review refunds, taxes and tips separately where indicated.', 'Compare equivalent periods and sources. Processor reports and deposits must not be added to sales as extra revenue.'],
      question: 'Should you add a processor deposit to the sales total?', choices: ['Yes, it is another sale', 'No, it represents a different stage of the money flow', 'Only if it arrived today'], answer: 1,
      explanation: 'Sales and deposits can describe the same money at different stages. Adding them can double count it.', destination: '/sales', action: 'Open sales' },
    { key: 'books', title: 'Review and close a day', minutes: 4, permission: 'reports.read', paths: ['/books', '/bookkeeping', '/financial_close', '/daily_reconciliations', '/bank_statements', '/finance', '/books_check', '/reconciliation_follow_ups', '/money_reconciliations', '/cash_forecast'], terms: %w[reconciliation snapshot period_lock follow_up],
      summary: 'Work through evidence, differences and follow-ups in order.',
      steps: ['Open Close & review and follow the next unfinished day. Check that expected source reports and originals are present.', 'Compare matching dates, currencies and locations. Document timing, fees and unexplained differences with evidence.', 'Assign unresolved follow-ups, then review the current data. Changed evidence requires a fresh review; a retained close package does not finish open follow-ups.'],
      question: 'Source evidence changed after you reviewed the day. What next?', choices: ['Keep relying on the old review', 'Delete the source evidence', 'Review the updated evidence again'], answer: 2,
      explanation: 'Reviews refer to a particular version of the evidence. Recheck the changed day.', destination: '/books', action: 'Open Close & review' },
    { key: 'work', title: 'Track work and goals', minutes: 2, permission: 'projects.read', paths: ['/projects', '/goals'], terms: %w[kpi],
      summary: 'Give each task a clear outcome and each measure a useful target.',
      steps: ['Open the project and find the task that needs action. Check its owner and due date.', 'Move tasks as the work progresses and record enough detail for the next person.', 'Read each KPI’s unit, period and target together. A number without its definition cannot explain progress.'],
      question: 'What makes a KPI useful?', choices: ['A number with a clear unit, period and target', 'The largest possible number', 'A title alone'], answer: 0,
      explanation: 'The unit, period and target give the measurement meaning.', destination: '/projects/projects', action: 'Open projects' }
  ].freeze

  def self.available(user)
    LESSONS.select { |lesson| lesson[:permission].nil? || (lesson[:permission] == 'pos' ? user.can_use_pos? : user.can?(lesson[:permission])) }
  end

  def self.for_path(path, user)
    available(user).select { |lesson| lesson[:paths].any? { |prefix| path == prefix || path.start_with?("#{prefix}/") } }
      .max_by { |lesson| lesson[:paths].select { |prefix| path == prefix || path.start_with?("#{prefix}/") }.map(&:length).max }
  end
end
