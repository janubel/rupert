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
