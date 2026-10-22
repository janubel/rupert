# frozen_string_literal: true

# Fictional examples teach a decision without touching operational records.
class LearningExamples
  EXAMPLES = {
    'start' => {
      title: 'An empty report needs context',
      context: 'It is Tuesday morning. The report is set to Monday and its last successful source pull was Sunday.',
      rows: [['Selected business date', 'Monday'], ['Latest source pull', 'Sunday'], ['Recorded Monday sales', '$0.00']],
      takeaway: 'The report has no imported Monday sales. Select the intended date and verify a current pull before treating zero as no business activity.'
    },
    'setup' => {
      title: 'Saved → read → checked',
      context: 'You have saved a store connection. The store has a known sale from yesterday.',
      rows: [['Credentials', 'Saved locally'], ['Successful source read', 'Not recorded'], ['Known sale in Rupert', 'Not yet verified']],
      takeaway: 'Continue with an authorized source pull, review its outcome, then find yesterday’s known sale. A saved status alone does not establish working data.'
    },
    'checkout' => {
      title: 'Read the amount due and cash change',
      context: 'A checked example cart has a $36.00 subtotal, $2.16 tax and a $5.00 customer-confirmed tip.',
      rows: [['Subtotal', '$36.00'], ['+ Tax', '$2.16'], ['+ Tip', '$5.00'], ['= Total due', '$43.16'], ['Cash received', '$50.00'], ['Change: $50.00 − $43.16', '$6.84']],
      takeaway: 'Use the checked total to collect payment. Cash received includes the money returned as change; it is not the sale amount. Check an unfinished receipt before trying payment again.'
    },
    'staff' => {
      title: 'An estimate depends on recorded hours',
      context: 'Your example timesheet has 8 regular hours at $20 per hour. You actually worked 7.5 hours.',
      rows: [['Recorded estimate: 8 × $20', '$160.00'], ['Hours you worked', '7.5 hours'], ['Corrected example: 7.5 × $20', '$150.00']],
      takeaway: 'Request a correction before submitting the timesheet. These examples use regular hours only; actual pay can include other earnings and deductions.'
    },
    'stock' => {
      title: 'One shelf, two observations',
      context: 'Shopify and C-Trax observe the same shelf. A separate observation reports 10 on hand, of which 3 are committed.',
      rows: [['Shopify observation', '10 units'], ['C-Trax observation of the same stock', '10 units'], ['Physical stock to verify', 'One set of units, not 20'], ['Example on hand − committed: 10 − 3', '7 available units']],
      takeaway: 'Do not add shared-source quantities. On-hand and available also describe different things; read the source’s own fields and timestamp.'
    },
    'counts' => {
      title: 'A count is evidence of what you found',
      context: 'The submitted worksheet compares a physical count against a captured source quantity for the same item and location.',
      rows: [['Captured comparison', '10 units'], ['Physical count', '8 units'], ['Variance: 8 − 10', '−2 units'], ['Platform adjustment', 'Separate task']],
      takeaway: 'A negative variance means fewer units counted than the comparison. An unknown comparison stays unknown rather than becoming a zero.'
    },
    'sales' => {
      title: 'Sales, averages and deposits tell different stories',
      context: 'Two included USD sales on the selected day are $30 and $20. A separate processor report shows a $44 deposit.',
      rows: [['Included sale A', '$30.00'], ['+ Included sale B', '$20.00'], ['= Recorded sales before refunds', '$50.00'], ['Average: $50 ÷ 2 sales', '$25.00'], ['Processor deposit, kept separate', '$44.00']],
      takeaway: 'Recorded sales are $50, not $94. Investigate the deposit’s period, fees, refunds and timing separately. The order journal’s status filter does not change the sales summary.'
    },
    'books' => {
      title: 'Explain a difference before closing',
      context: 'For the same period and currency, recorded sales are $100 and documented bank funding is $97.',
      rows: [['Recorded sales', '$100.00'], ['Bank funding evidence', '$97.00'], ['Difference to explain', '$3.00'], ['Possible explanation', 'A fee, only if evidence supports it']],
      takeaway: 'Do not invent a fee to force a match. Verify it in source evidence or assign a follow-up. Review again if the underlying evidence changes.'
    },
    'sync' => {
      title: 'A green pull is a start, not a proof',
      context: 'The Shopify pull finished at 9:05 with no error. A customer says they ordered at 8:40.',
      rows: [['Last Shopify pull', '9:05, success'], ['Customer’s order time', '8:40'], ['Order found in Rupert?', 'Check the journal'], ['If missing', 'Investigate the read; do not type it in']],
      takeaway: 'A successful status means the read finished. Confirm a known record exists before trusting a total, and never hand-enter source data to patch a gap.'
    },
    'access' => {
      title: 'The smallest access that does the job',
      context: 'A fictional cashier, Priya, needs to check yesterday’s sales report once for a manager who is away.',
      rows: [['Role today', 'Cashier'], ['Needed', 'Reports, read-only, once'], ['Poor fix', 'Promote to administrator'], ['Better fix', 'Run the report for her, or add a narrow reviewable override']],
      takeaway: 'Roles describe everyday work. Exceptions should be rare, narrow and reviewed. Administrator and platform roles are never a shortcut.'
    },
    'customers' => {
      title: 'Lifetime value only counts what is stored',
      context: 'A fictional customer has three recorded orders and one cash sale that was never imported.',
      rows: [['Recorded order A', '$40.00'], ['Recorded order B', '$25.00'], ['Recorded order C', '$35.00'], ['Lifetime value shown', '$100.00'], ['Unimported cash sale', 'Not included']],
      takeaway: 'The figure is the sum of stored orders attributed to this profile. Check source coverage and profile matching before concluding a customer spends less than you remember.'
    },
    'alerts' => {
      title: 'From pace to a suggestion',
      context: 'A fictional item has 4 units at the website location and 2 at the register. It sold 30 units in the last 30 days.',
      rows: [['On hand: 4 + 2', '6 units'], ['Sold in 30 days', '30 units'], ['Pace: 30 ÷ 30', '1 unit per day'], ['Days of cover: 6 ÷ 1', '6 days'], ['30 days of pace: 1 × 30', '30 units'], ['Suggested reorder: 30 − 6', '24 units']],
      takeaway: 'Cover and the suggestion follow directly from on hand and pace. Check pack sizes, lead time and season before ordering; nothing is ordered automatically.'
    },
    'reports' => {
      title: 'Profit depends on what was recorded',
      context: 'A fictional 30-day financial report shows $5,000 recorded sales and $3,000 recorded expenses. A $600 supplier invoice has not been entered.',
      rows: [['Recorded sales', '$5,000.00'], ['Recorded expenses', '$3,000.00'], ['Profit shown: 5,000 − 3,000', '$2,000.00'], ['Missing invoice', '$600.00'], ['Profit after recording it', '$1,400.00']],
      takeaway: 'A missing expense inflates profit. Record what is missing, then read the report again for the same window.'
    },
    'timesheet_review' => {
      title: 'Return with a reason, not a shrug',
      context: 'A fictional submitted week shows 9 hours on Tuesday. Punches and the schedule both show 7.',
      rows: [['Submitted Tuesday', '9.0 h'], ['Punches', '9:00 → 16:00 = 7.0 h'], ['Scheduled', '7.0 h'], ['Difference to explain', '2.0 h'], ['Decision', 'Return with a note']],
      takeaway: 'Ask about the two hours in the note. The person corrects or explains, then resubmits. Approving the week as-is would pay time the evidence does not support.'
    },
    'receipts_review' => {
      title: 'The image is the evidence',
      context: 'A fictional receipt is submitted for $48.20 with the purpose “cleaning supplies”. The photo shows $43.20.',
      rows: [['Typed total', '$48.20'], ['Total on the image', '$43.20'], ['Difference', '$5.00'], ['Decision', 'Reject with a note asking for the correct amount']],
      takeaway: 'Approve only when the typed details match the original. Approval records a bookkeeping decision; it does not pay anyone.'
    },
    'team_chat' => {
      title: 'Ask every bot, keep the best answer',
      context: 'A fictional manager writes "@all how were sales yesterday?" in #admins.',
      rows: [['@rupert (cloud)', '4 s — 2 orders, $214.83, all Shopify'], ['@qwen (local)', '41 s — same total, shorter'], ['@liquid (local)', '55 s — missed the refund'], ['Your rating', '👍 @rupert, 👎 @liquid: “ignored the refund”']],
      takeaway: 'Comparing side by side and noting why turns everyday questions into a record of which model to trust.'
    },
    'tasks' => {
      title: 'Make a blocker actionable',
      context: 'A fictional task asks you to prepare a shelf display. Its product list has not been provided.',
      rows: [['Assignee', 'You'], ['Current obstacle', 'Missing product list'], ['Useful status', 'Blocked'], ['Useful note', 'Please attach the approved product list so I can finish the display.']],
      takeaway: 'The note explains what is missing and what will let work continue. Keep the task open until its outcome is complete.'
    },
    'work' => {
      title: 'A measure needs a target and a period',
      context: 'A fictional project aims to complete 20 follow-up calls this week. The recorded result is 12.',
      rows: [['Target', '20 calls this week'], ['Recorded result', '12 calls'], ['Progress: 12 ÷ 20 × 100', '60%'], ['Remaining to target', '8 calls']],
      takeaway: '60% is meaningful because the unit, target and reporting period are clear. Record the next action and its owner.'
    }
  }.freeze

  def self.for(key)
    EXAMPLES.fetch(key)
  end
end
