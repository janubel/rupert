# Projects and Tasks

Work lives under **Work → Projects** and **Work → Tasks**. Staff accounts see only **My tasks**.
This page records what the module does, how its data is shaped, and what an operator needs to know.

## What it does

| Area | Behaviour |
| --- | --- |
| Projects | Name, description, start and due dates, owner, team members, optional goal. Lifecycle: planned → active ⇄ on hold → completed → archived; **reopen** returns a completed or archived project to active. |
| Completing | A project with unfinished tasks cannot be completed without an explicit choice: mark them done (tasks that still wait on others are reported and left open) or leave them open. |
| Tasks | Title, notes, priority, start and due dates, assignee, labels (up to 10), estimate, repeat. Lifecycle: to do, in progress, blocked, done. |
| Task page | `/projects/tasks/:id`: checklist (50 items), discussion, time entries, files (PNG, JPG, GIF, PDF, TXT, CSV; 5 MB each; 10 per task), dependencies, history from the audit trail. |
| Blocked | Blocking records a reason (up to 1,000 characters). Leaving the blocked or done state clears it. The project owner, team and assignee are notified. |
| Dependencies | A task can wait on other tasks. It cannot be started or finished until they are done; cycles are refused; the assignee is notified when it becomes free. Managers (`projects.write`) set them. |
| Repeating | Daily, weekly, every 2 weeks, monthly, yearly. Finishing a repeating task creates the next copy (assignee, labels, estimate, unticked checklist), dated one interval later and never in the past. Once per task. |
| Board order | Dragging within a column stores `tasks.position`. Tasks never placed follow by priority and due date. |
| Views | Board, list, calendar (by due date) on Tasks; board and timeline on a project. Board moves refresh totals in place. |
| Templates | **Save template** on a project stores its tasks, checklists and date offsets as one JSON document (`project_templates`). Templates are not projects and never show on a board. |
| Goals | `projects.goal_id` must be a goal in the same workspace. The goal page lists linked projects with progress. |
| Export | **Export CSV** on Tasks (honours filters) and Projects. Cells that start with `=`, `+`, `-` or `@` are neutralised; each export is written to the activity log. |
| Notifications | In-app only. A bell in the header lists assignments, comments, blocked work, tasks freed by a finished dependency and recurrences. `TaskReminderJob` (07:30 America/New_York, `config/recurring.yml`) adds "due today" and a weekly "overdue" reminder, each with a dedupe key so reruns send nothing twice. People never notify themselves. |
| Dashboard | **My tasks** widget (needs `projects.read` or `tasks.self`). |

## Access

Unchanged from the readiness review: `projects.read` views, `projects.write` plans (create, delete,
reassign, dates, dependencies, templates, export of projects). Staff (`tasks.self`) work only on tasks assigned to
them: they can edit title and notes, comment, tick the checklist, log time, attach files and block or finish.
Team membership only decides who is notified. Staff endpoints are added to the boundary list in
`ApplicationController#enforce_employee_boundary`; the task detail and its children use the same
assignment check as the board.

Attachments are stored in the database (like feedback attachments), validated by extension and file signature,
and only ever served as downloads.

## Operations

* **Migration `20261023120000`.** Adds the new tables and columns and converts `tasks.project_id` from a string
  to an integer with a foreign key to `projects`. Before the change, any `project_id` that does not name a project in
  the **same workspace** (stray text, deleted or foreign projects) is set to NULL, so those tasks become unfiled
  work rather than failing the migration. Back up first (the normal procedure); the migration is reversible in
  schema but not in the cleared references.
* **Reminders** need the Solid Queue recurring schedule (already used by other jobs). There is no email
  delivery configured in Rupert, so notifications are in-app only.
* **Not done here:** email or push delivery, @mentions, task subtasks (use the checklist), per-person
  notification preferences, and acceptance in the intended production workspace.

## Before deploying: what the migration would clear

Auto-deploy runs the migration unattended. This read-only query lists the tasks whose `project_id` will be set to
NULL (it points at no project in the task's own workspace). Such tasks already show as unfiled, so nothing visible
changes; the query only tells you whether any stray values exist.

```sql
SELECT t.id, t.tenant_id, t.project_id FROM tasks t
WHERE t.project_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM projects p WHERE p.id = CAST(t.project_id AS INTEGER) AND p.tenant_id = t.tenant_id);
```
