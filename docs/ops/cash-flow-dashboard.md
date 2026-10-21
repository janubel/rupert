# Cash flow dashboard

**Bookkeeping → Cash flow** (`/finance/cash_flow`, permission `finance.read`) answers "where is the money?" for a date
range, live. It sits beside Bookkeeping on purpose: Bookkeeping is where lines get decisions; Cash flow is where the
decided (and undecided) picture is read. Nothing on the page posts, matches or infers.

## What each block reads

| Block | Source | Rule |
| --- | --- | --- |
| Into / out of the bank, net, running net | `bank_statement_lines` by `posted_on`, optionally one `account_label` | signed cents; a payout is money in, a transfer out is money out; undecided lines count |
| Sales taken, by channel | `DashboardSales` (paid/fulfilled canonical orders + completed C-Trax sales, USD) | same rows and warnings as the home dashboard; before refunds; what was sold, not what was deposited |
| Spend recorded, where the money went | `expenses` by `incurred_on` (by category) + `vendor_payments` by `paid_on` | undiscarded only |
| What left the bank, by type | bank withdrawals grouped by `review_category` | "Not yet reviewed" is its own bucket and shrinks as lines get decisions |
| From sale to bank | sales − refunds − statement credits reviewed as **Processor payout** | a comparison, not a reconciliation; the remainder is fees, cash sales, timing and undecided lines |
| Where cash stands | `BookkeepingOverview#statement_balance` (retained statement with a closing balance) | Unavailable is not zero; runway = balance ÷ average daily net, only when net is negative |
| Latest money events | newest payments, bank lines, expenses and vendor payments | newest first across sources, 12 shown |
| Change vs previous | the same report for the window of equal length ending the day before | zero or missing previous → "no comparison" |

Buckets: daily up to 45 days, weekly to 200 days, monthly beyond. Headline figures are compact (`$12.4K`); the exact
amount is in the tooltip, the tables and the JSON.

## Live refresh

The page polls itself every 30 seconds (`Accept: text/vnd.turbo-stream.html`) while the tab is visible. The server
replaces the figure, table, position, spend, deposits and event regions in place and swaps the embedded JSON block;
the Stimulus controller (`cash_flow_controller.js`) re-reads that block and updates the two Chart.js charts without
recreating them. "Live · refreshed Ns ago" in the header goes grey when three refreshes are missed.

## Colour

Chart colours are theme tokens in `app/assets/tailwind/application.css` (`--chart-1..4` categorical slots in fixed
order, `--chart-in` / `--chart-out` for money in vs out, `--chart-muted`), one set for the light appearances and one for
dark. Both sets were run through the dataviz palette validator (lightness band, chroma floor, colour-vision-deficiency
separation, 3:1 contrast on the card surface); the light set's weakest neighbour pair (green ↔ orange, ΔE 6.3 under
protanopia) is legal because every stacked chart also has a legend and 2px gaps, and every chart has a table twin.
Channels keep a fixed slot (Shopify 1, Square 2, C-Trax 3, SwipeSimple 4, others cycle; "Other" is muted) so a channel
never changes colour when another overtakes it. Text never wears a data colour.

## JSON

`GET /finance/cash_flow.json?range=90d&account=Operating` returns the same figures (`range`, `kpis`, `bank`,
`channels`, `spend`, `bank_out`, `deposits`, `position`, `events`, `warnings`). Same permission as the page.
