# Next thing to do and ops mode

Added 2026-10-23 at the owner's request: a bar at the top of every page with the one thing that needs you
next, and an ops mode that works the whole list one item at a time.

## What shows

`NextThings` gathers items from the same read-only checks the assistants use, run as the signed-in person,
so everyone sees only what they may act on:

| Area | Source | Fix | Watch |
| --- | --- | --- | --- |
| Sync | `sync_health` (system read) | a source whose latest read failed | |
| Orders | `order_queues` (reports read) | a queue with late items | any other waiting queue |
| Tasks | `list_tasks` | your overdue tasks (up to 3) | other overdue tasks on the board |
| Books, close, People, Records | `compliance_check` (finance read) | its fix items | its watch items |
| Stock | `list_alerts` (alerts read) | | open low-stock alerts |

Someone those checks do not cover (for example an employee account) sees their own late tasks (Fix) and
tasks due today (Watch). The bar is in both the management app and the employee app (`layouts/employee`);
`restrict_employee_workspace` allows `next_things` for employees, who only ever get their own tasks there. Fix comes before Watch; within each, broken data first, then customers waiting,
then people's work, then paperwork. Results are cached two minutes per person.

## Buttons

- **Open** goes to the page that fixes the item.
- **Done** hides the item until it changes. A Fix item marked done comes back after 12 hours if it is still
  open, so a real problem cannot be hidden for good.
- **Snooze 1 h** hides it for an hour.
- **Start ops mode** / **Exit ops mode**: in ops mode the bar shows "3 of 7" and **Skip** moves on; after the
  last item it starts again from the top. When the list is empty it says "All clear".

Done and Snooze are saved per person (`next_thing_dismissals`); ops mode and skips are per browser session.
The bar loads into its own lazy Turbo Frame (`GET /next_thing`) so it never slows a page down, and its buttons
redraw only the bar.
