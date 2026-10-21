# frozen_string_literal: true

# Short guided tours that point at real elements on a page. A view marks an
# element with `data-tour="<anchor>"` (see LearningHelper#tour_anchor); the
# tour controller highlights each anchored element in order and skips steps
# whose anchor is not on the page for this person. Tours never start by
# themselves: the help bar and the welcome card offer them, and finishing or
# skipping one records it for the account so the offer quietens down.
#
# Steps also render as a plain numbered list inside "How this page works", so
# the same guidance is available without JavaScript.
class PageTours
  Tour = Struct.new(:key, :title, :intro, :steps, :paths, :permission, keyword_init: true) do
    def minutes
      [1, (steps.size / 3.0).ceil].max
    end

    # The first path is the page to open for this tour.
    def path
      paths.first
    end
  end

  TOURS = [
    Tour.new(
      key: 'dashboard', title: 'Your dashboard in 60 seconds', paths: ['/'], permission: 'dashboard.read',
      intro: 'Where the numbers come from, what needs you and where to go next.',
      steps: [
        { anchor: 'areas', title: 'Work areas', body: 'The header groups tools by what you do: Sell, Stock, Bookkeeping, Work, Team and System. Only areas your account can use are shown.' },
        { anchor: 'tools', title: 'Tools in this area', body: 'Inside an area, open this menu to switch between its tools. The current tool is marked.' },
        { anchor: 'stats', title: 'Key stats', body: 'Recorded sales from paid orders and completed register sales, before refunds. Open “What’s in this total?” on any card for the exact rule.' },
        { anchor: 'attention', title: 'Needs attention', body: 'Ordered by severity. Start your day here: SKU mismatches and low stock appear before anything else.' },
        { anchor: 'customize', title: 'Make it yours', body: 'Show, hide and reorder widgets. Your layout is saved to your account, not this browser.' },
        { anchor: 'help', title: 'Help is one tap away', body: 'Press ? or use this button on any page for how it works, definitions, lessons and a tour like this one.' }
      ]
    ),
    Tour.new(
      key: 'sales', title: 'Reading the sales page', paths: ['/sales'], permission: 'sales.read',
      intro: 'Pick a day, understand the total, then dig into the journal.',
      steps: [
        { anchor: 'filters', title: 'Choose what you are looking at', body: 'Set the business date, the chart period and the source. Every number on the page follows these choices.' },
        { anchor: 'summary', title: 'Recorded sales', body: 'Paid or fulfilled orders and completed register sales for the selected day, before refunds. Tips, payments and deposits are kept separate.' },
        { anchor: 'explanation', title: 'What makes up these totals?', body: 'Opens the exact included amounts per source and the average calculation for the day you selected.' },
        { anchor: 'sources', title: 'Source freshness', body: 'Each source shows when Rupert last pulled it. A zero with an old pull is a missing import, not a quiet day.' },
        { anchor: 'journal', title: 'The order journal', body: 'Every canonical order for the day with its own status and currency. The status filter changes only this list.' }
      ]
    ),
    Tour.new(
      key: 'inventory', title: 'How to read stock', paths: ['/inventory'], permission: 'inventory.read',
      intro: 'Identify the item, then read each quantity with its source and time.',
      steps: [
        { anchor: 'search', title: 'Find an item', body: 'Search by product name or SKU. A SKU can be shared, so check the product and variant before acting.' },
        { anchor: 'locations', title: 'One column per location', body: 'Shopify and register locations hold separate inventories. Different numbers across columns are normal, not drift.' },
        { anchor: 'mirror', title: 'Mirror quantity', body: 'The last quantity read from the source. Unknown is shown differently from zero, and both are different from a physical count.' },
        { anchor: 'actions', title: 'Counts and history', body: 'Start a count when the mirror looks wrong. Approving a count records evidence here; it never changes a platform by itself.' }
      ]
    ),
    Tour.new(
      key: 'alerts', title: 'Turning alerts into restock decisions', paths: ['/alerts'], permission: 'alerts.read',
      intro: 'Each alert carries on-hand, sales pace and a suggested quantity. Nothing is ordered for you.',
      steps: [
        { anchor: 'tabs', title: 'Open, resolved, ignored', body: 'Open alerts sort by urgency: fewest days of cover first. Resolved and ignored are kept for review.' },
        { anchor: 'pace', title: 'Sales pace', body: 'Units sold in the last 14 and 30 days across every channel. Pace drives the days of cover.' },
        { anchor: 'cover', title: 'Days of cover', body: 'Roughly how long current stock lasts at the recent pace. Under seven days is highlighted.' },
        { anchor: 'suggested', title: 'Suggested reorder', body: 'Enough to cover about 30 days at the recent pace, minus what you hold. Advice only; confirm with the supplier and the shelf.' },
        { anchor: 'bulk', title: 'Resolve or ignore', body: 'Tick several rows to update them together. Resolving records your decision; stock is not changed.' }
      ]
    ),
    Tour.new(
      key: 'inventory_counts', title: 'Counting stock', paths: ['/inventory_counts'], permission: 'inventory.read',
      intro: 'A count is evidence of what you found, kept for review.',
      steps: [
        { anchor: 'start', title: 'Start a count', body: 'Scan or type quantities for one location. Record a real zero when the shelf is empty.' },
        { anchor: 'status', title: 'Draft, pending, approved', body: 'Drafts are yours to change. Submitting captures the comparison quantity; approval records the count.' },
        { anchor: 'table', title: 'Review past counts', body: 'Open any sheet to see counted versus comparison quantities and the variance for each item.' }
      ]
    ),
    Tour.new(
      key: 'learning', title: 'Around Learn Rupert', paths: ['/learning'], permission: nil,
      intro: 'Lessons, your path and every definition in one place.',
      steps: [
        { anchor: 'path', title: 'Your path', body: 'A short sequence of lessons suggested for your work. Change it any time; it never changes your permissions.' },
        { anchor: 'search', title: 'Find anything', body: 'Search lessons and definitions together. Try a word you saw on a page.' },
        { anchor: 'lessons', title: 'All lessons', body: 'Each one has steps, a fictional example, a short check and a link to the real tool.' },
        { anchor: 'definitions', title: 'Words and numbers', body: 'The same wording Rupert uses beside the work, explained in plain language.' }
      ]
    ),
    Tour.new(
      key: 'employee_home', title: 'Your staff home', paths: ['/employee'], permission: 'staff',
      intro: 'Clock in, see your week and send things for review.',
      steps: [
        { anchor: 'nav', title: 'Your workspace', body: 'POS, receipts, timesheets, schedule and time off. Everything here is about your own records.' },
        { anchor: 'clock', title: 'Clock in and out', body: 'Clock in when you start. Your elapsed time shows here while you are working.' },
        { anchor: 'week', title: 'This week', body: 'Recorded hours and an estimated gross pay before deductions. Request a correction if a day looks wrong.' },
        { anchor: 'help', title: 'Help any time', body: 'Learn Rupert & definitions in the footer explains every word and number you will see here.' }
      ]
    ),
    Tour.new(
      key: 'customers', title: 'Around the customer list', paths: ['/customers'], permission: 'customers.read',
      intro: 'Find a person, read where their profile came from, then act on follow-ups.',
      steps: [
        { anchor: 'actions', title: 'Add, export, sync', body: 'Add a customer by hand or export the rows that match your current filters. Sync pulls directory profiles from connected sources; nothing is pushed back.' },
        { anchor: 'stats', title: 'Counts at a glance', body: 'All customers includes retained history from every source. Leads, VIPs and due follow-ups are filters; tap one to open it.' },
        { anchor: 'search', title: 'Search and filter', body: 'Search by name, email or phone. More filters narrow by tag, source, directory verification and who the customer is assigned to.' },
        { anchor: 'table', title: 'One row per profile', body: 'Source shows which platform supplied the profile and whether the latest read verified it. Orders and lifetime totals are per currency and never added across currencies.' },
        { anchor: 'sources', title: 'Where customers come from', body: 'Directory coverage per provider with the last complete read. Existing records alone do not prove the directory is complete.' }
      ]
    ),
    Tour.new(
      key: 'sync', title: 'Reading the sync page', paths: ['/syncs'], permission: 'sync.read',
      intro: 'Syncs are read-only mirrors of Shopify and Square into Rupert.',
      steps: [
        { anchor: 'run', title: 'Run a sync', body: 'Queue a pull from every source or a single one. Running needs sync-write permission and reads only; nothing is written to a platform.' },
        { anchor: 'banner', title: 'Live status', body: 'While a sync runs this banner says so and the page refreshes itself when it finishes.' },
        { anchor: 'runs', title: 'Sync runs', body: 'Every run with its mode, source and status. A green run means the job finished without an error, not that every record arrived; check freshness on the page you care about.' },
        { anchor: 'movements', title: 'Recent inventory activity', body: 'Quantity changes observed during syncs, with the before and after numbers and the source that reported them.' }
      ]
    ),
    Tour.new(
      key: 'connections', title: 'Credentials and sync health', paths: ['/connections'], permission: 'settings.read',
      intro: 'Set up a connection, confirm it reads, then watch freshness separately.',
      steps: [
        { anchor: 'actions', title: 'Jump to a section', body: 'Credential setup and the improvement plan are further down this page. Sync history and worker status open their own pages.' },
        { anchor: 'flow', title: 'Save, check, read, review', body: 'Saved credentials and a passing access check do not prove new data is arriving. Completeness and freshness are shown separately, and opening this page starts nothing.' },
        { anchor: 'health', title: 'Sync health and repair', body: 'One card per source with its badge, schedule, last source evidence and the next repair step. Read source now runs a single pull when the source allows it.' },
        { anchor: 'credentials', title: 'Credential setup', body: 'Configured means the required fields are saved, not that vendor access was checked. Blank secret fields keep their saved values; only settings-write accounts can replace them.' },
        { anchor: 'improvements', title: 'Improvement plan', body: 'What this desk already does, what is planned, and what to do when a check passes but data stays stale.' }
      ]
    ),
    Tour.new(
      key: 'ctrax_pos', title: 'Selling with C-Trax retail', paths: ['/ctrax_pos'], permission: 'pos',
      intro: 'Check the stock read, find products, check the cart, then let the customer confirm privately.',
      steps: [
        { anchor: 'store', title: 'Store and stock freshness', body: 'The store you are selling from and when its stock was last read. A stale read disables Add until someone refreshes the C-Trax connection.' },
        { anchor: 'search', title: 'Find a product', body: 'Switch store or category, or search by name, SKU or barcode. Only products with a linked website image are shown.' },
        { anchor: 'products', title: 'Products', body: 'Each card shows the source price and tracked stock. Variable-price items must be sold in C-Trax itself.' },
        { anchor: 'cart', title: 'Cashier cart', body: 'Check cart re-reads source prices and tax before checkout. Adding items does not reserve stock.' },
        { anchor: 'display', title: 'Customer screen', body: 'Pair a second screen so the customer confirms their tip privately. Demo both screens simulates payment and never creates a live sale.' },
        { anchor: 'unfinished', title: 'Unfinished checkouts', body: 'A checkout that was started but not completed waits here. Check its receipt before collecting another payment.' }
      ]
    ),
    Tour.new(
      key: 'timesheets', title: 'Reviewing timesheets', paths: ['/people/timesheets'], permission: 'timesheets.read',
      intro: 'Work the review queue, then compare sources without adding overlapping hours.',
      steps: [
        { anchor: 'tabs', title: 'Needs review first', body: 'Submitted timesheets wait here. Approved, returned and drafts are kept for reference; your own timesheets need another reviewer.' },
        { anchor: 'next', title: 'Where to go next', body: 'Staff profiles, time off, punch calendar, payroll and the imported Square and C-Trax histories.' },
        { anchor: 'weeks', title: 'Upcoming weeks', body: 'Timesheets on file per week, split by status. Open a week to review only what is in it.' },
        { anchor: 'sources', title: 'Separate time sources', body: 'Rupert submissions, Square timecards and C-Trax shifts are separate records. Review each; overlapping hours must not be added together, and none of them pays anyone.' },
        { anchor: 'views', title: 'List, unified, calendar', body: 'Rupert timesheets is the review list. All sources shows every record side by side; Calendar lays them out by day.' },
        { anchor: 'table', title: 'The review list', body: 'Hours by type, compensation and check flags per timesheet. Tick submitted rows to approve several at once with one note.' }
      ]
    ),
    Tour.new(
      key: 'employees', title: 'Around the staff directory', paths: ['/people/employees'], permission: 'hr.read',
      intro: 'Profiles, their source identities and whether each person can sign in.',
      steps: [
        { anchor: 'actions', title: 'Departments, positions, add', body: 'Manage departments and positions, add a staff member by hand, or sync the directory from connected sources. Consolidation merges duplicate profiles while keeping every source identity.' },
        { anchor: 'sync', title: 'Directory coverage', body: 'Per provider: the last complete read and any error. Existing records alone do not verify a complete roster.' },
        { anchor: 'stats', title: 'Team counts', body: 'Active staff, timesheets awaiting review, pending leave and departments. Only the counts your permissions allow are shown.' },
        { anchor: 'filters', title: 'Find a person', body: 'Search by name, staff number or email, then narrow by status, source or whether they have a login.' },
        { anchor: 'table', title: 'One row per profile', body: 'Each row lists the source identities behind the profile, the login state and which tabs that login can open. Confirm employment type and payroll details before running payroll.' }
      ]
    ),
    Tour.new(
      key: 'receipts', title: 'Receipts in a minute', paths: ['/receipts'], permission: nil,
      intro: 'Submit a purchase receipt, or review the ones waiting for you.',
      steps: [
        { anchor: 'new', title: 'Upload a receipt', body: 'Attach the receipt, enter the payee, date and amount. It then waits for a reviewer.' },
        { anchor: 'awaiting', title: 'Awaiting approval', body: 'Approval records a review only. It does not pay a reimbursement or add an expense to the books.' },
        { anchor: 'status', title: 'Filter by status', body: 'Reviewers land on Submitted so the queue comes first; everyone else starts with all of their own receipts. Returned means a reviewer sent it back for correction.' },
        { anchor: 'table', title: 'The list', body: 'Reviewers see every submission with who sent it. Submitters see only their own.' }
      ]
    ),
    Tour.new(
      key: 'tasks', title: 'Working the task board', paths: ['/projects/tasks'], permission: 'projects.read',
      intro: 'Everything in flight across projects, as a board or a list.',
      steps: [
        { anchor: 'guide', title: 'Getting started', body: 'A short guide to projects, tasks and goals if this area is new to you.' },
        { anchor: 'views', title: 'Board or list', body: 'The board groups tasks by status and supports dragging. The list sorts by priority and pages through everything.' },
        { anchor: 'stats', title: 'Open, blocked, overdue', body: 'Open counts to do, in progress and blocked together. Tap a tile to filter to it; overdue uses the due date.' },
        { anchor: 'filters', title: 'Narrow the view', body: 'Search, pick a project or priority, or switch on Mine, Overdue and Due this week.' },
        { anchor: 'board', title: 'The columns', body: 'Drag a card to another column to change its status, if you can write tasks. Blocked tasks stay visible until someone unblocks them.' }
      ]
    ),
    Tour.new(
      key: 'users', title: 'Accounts and roles', paths: ['/users'], permission: 'users.read',
      intro: 'Who can sign in, and what their role lets them see.',
      steps: [
        { anchor: 'permissions', title: 'Permissions', body: 'What each role can read and write. Roles decide which areas appear, and the server re-checks every request regardless of what is shown.' },
        { anchor: 'add', title: 'Add an account', body: 'Create a login and give it a role. Only administrators with users-write can add, edit or remove accounts.' },
        { anchor: 'table', title: 'All accounts', body: 'One row per login. HR records such as pay and leave live under Staff, not here.' },
        { anchor: 'roles', title: 'Role', body: 'The role sets the baseline permissions. Changing it changes what the person sees on their next request.' },
        { anchor: 'status', title: 'Active or deactivated', body: 'Deactivated accounts cannot sign in but keep their history. Reactivate restores access without creating a new account.' }
      ]
    ),
    Tour.new(
      key: 'books_desk', title: 'Closing the books', paths: ['/books'], permission: 'reports.read',
      intro: 'Finish each day, then each week, then lock the period. Nothing here changes a record by itself.',
      steps: [
        { anchor: 'next', title: 'Do this next', body: 'The oldest unfinished day and its next step, so a backlog is worked in order. When days are done, the weekly chore or period end takes its place.' },
        { anchor: 'record', title: 'Record something now', body: 'Upload a bank statement, add an expense or vendor payment, or track a follow-up without leaving the routine.' },
        { anchor: 'findings', title: 'What needs reconciliation', body: 'Square sales without a payment and unpaid SwipeSimple invoices. Open it for the detail.' },
        { anchor: 'this_week', title: 'This week so far', body: 'Each finished day and its six steps. Today is still open and appears tomorrow.' },
        { anchor: 'week', title: 'The week under review', body: 'Weekly chores on the left, each day of that week on the right, with the week approval state. Step back to earlier weeks here.' },
        { anchor: 'periods', title: 'Month, quarter and year end', body: 'Finish every task, then lock the period so history cannot be edited by accident. Locks keep a dated archive of the totals.' }
      ]
    ),
    Tour.new(
      key: 'reports', title: 'Reading a report', paths: ['/reports'], permission: 'reports.read',
      intro: 'Pick the report, set the window, then export or cross-check.',
      steps: [
        { anchor: 'tabs', title: 'Report tabs', body: 'Sales, sales tax, financial, inventory, operations, reconciliation and the daily register. Each keeps the same date window as you switch.' },
        { anchor: 'window', title: 'Date window', body: 'Choose a preset such as last month or last quarter, or any from and to date, then Refresh. Every figure on the page follows this window.' },
        { anchor: 'columns', title: 'Your table, your columns', body: 'Pick which columns show, click a heading to sort, type to narrow rows, and download just what you see. Your layout is remembered in this browser.' },
        { anchor: 'check', title: 'Books check', body: 'Opens the health check for the same window: missing imports, unmatched payments and backups.' },
        { anchor: 'csv', title: 'Export CSV', body: 'Downloads the current report for the current window. Sources and currencies stay separate in the file.' }
      ]
    )
  ].freeze

  class << self
    def all
      TOURS
    end

    def find(key)
      TOURS.find { |tour| tour.key == key.to_s }
    end

    # Tours whose page this person can open. Staff accounts see only their own
    # workspace tours; other accounts see the pages their permissions allow.
    def available(user)
      TOURS.select { |tour| permitted?(tour, user) }
    end

    # Staff accounts only see their own workspace, their tasks and the register they can use.
    EMPLOYEE_TOURS = %w[employee_home learning tasks].freeze

    def permitted?(tour, user)
      return false unless tour && user&.active?
      return EMPLOYEE_TOURS.include?(tour.key) || (tour.key == 'ctrax_pos' && user.can_use_pos?) if user.employee?

      case tour.permission
      when nil then true
      when 'staff' then user.can?('timesheets.self')
      when 'pos' then user.can_use_pos?
      else user.can?(tour.permission)
      end
    end

    # The most specific tour whose path prefix matches and that this person may take, or nil.
    def for_path(path, user = nil)
      path = path.to_s
      (user ? available(user) : TOURS).select { |tour| tour.paths.any? { |prefix| matches?(path, prefix) } }
        .max_by { |tour| tour.paths.select { |prefix| matches?(path, prefix) }.map(&:length).max }
    end

    private

    def matches?(path, prefix)
      return path == '/' if prefix == '/'

      path == prefix || path.start_with?("#{prefix}/")
    end
  end
end
