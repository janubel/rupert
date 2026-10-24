# Team chat data map: which question goes where

Written 2026-10-23 after an audit of real chat questions. The bots only know the business through tools, so the
right answer depends on the question reaching the tool that reads where that data is actually stored. The data
guide (`config/team_chat/data_guide.yml`) carries this to the bots: a question's words pick its topic cards and
tools; the system prompt (`TeamChat::Agent#system_prompt`) repeats the rules that matter most.

## The finding that started this

"How much money has the store made today?" was answered with $731.14 from the order store (Shopify, Square,
Rupert POS and manual) while its own fine print said "C-Trax/SwipeSimple excluded". The store's in-person sales are
rung up on the SwipeSimple register (the main register since October 2026) and C-Trax, which no chat tool could
read. Every sales tool warned about it in its description; the bots did not pass the warning on, and the reply
called online sales "the store".

Fix: a `daily_close` tool (the Daily close page's figures, one row per store, never added together, unknown is
not zero), its own financial evidence contract, a `store_sales` data guide topic, a prompt rule that every sales
figure says what it covers, and three battery questions (f22–f24) so a regression is caught.

## Where each answer lives

| Question | Stored in | Tool | Notes |
| --- | --- | --- | --- |
| How much did the store make / register / takings / cash, card, tips | `SwipesimpleReportRow` (register transactions), `CtraxDay`, register orders | `daily_close` | one row per store; same as the Daily close page |
| Online and Square sales, orders, average order, top products, best day | `Core::Order` (Shopify, Square, Rupert POS, manual) | `metric`, `sales_summary`, `period_review`, `business_pulse` | never the store registers; say "online and Square" |
| Sales tax | every source | `sales_tax_report` | one line per source and store, never added |
| Refund rate, expenses by category | orders; expense register | `metric` | expenses are not profit; no cost of goods |
| What is waiting (unshipped, unpaid, POs, receipts, holds) | orders, purchasing, receipts | `order_queues` | |
| Stock levels, low stock, alerts | inventory levels, C-Trax snapshots, SwipeSimple items | `inventory_search`, `stock_comparison`, `swipesimple_items`, `list_alerts` | C-Trax is the retail count reference |
| Hours worked, timesheets, leave, pay runs | People | `time_keeping_report`, `compliance_check` | |
| Books closed, reviews, bank lines, uploads, retention | Books check, close checklists | `compliance_check` | |
| Tasks | Projects | `list_tasks` | |
| Is sync healthy | `SyncAttempt` | `sync_health` | |
| What history we hold | every source | `history_summary` | counts and dates, never amounts |

## Not answerable in chat yet (the bots should say so)

- Card deposits and payouts on the way (NAB/IRIS Daily Deposits) and Authorize.net batches.
- SwipeSimple invoices (paid or unpaid).
- Bank statement amounts (only "lines waiting" via `compliance_check`).
- Profit or margin: Rupert has no cost of goods.
- Customer rankings.

Each is a candidate for a read-only tool with an evidence contract, following `daily_close`. Until then the battery
keeps an honesty question for deposits (f21) and the profit margin (f20).

## How to check after a change

`bin/rails team_chat:battery BATTERY=finance AGENT=rupert` on the server asks the finance set (now including
f22–f24) and grades each answer against the tools' own output; Model scores shows the result.
