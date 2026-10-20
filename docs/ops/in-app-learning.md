# Onboarding and learning in Rupert

Open **Learn Rupert & definitions** from the account menu or staff footer. The
learning centre is at `/learning`; it is available to every signed-in, active
workspace account. Public documentation does not grant application access.

## First visit and everyday help

- Dashboard and My time offer the next unfinished lesson in a personal path.
  **Hide welcome** hides the card for that account across browsers. Help remains
  available. Choosing a path shows its welcome again.
- Paths cover workspace setup, customer checkout, stock, sales/bookkeeping,
  projects and personal hours. The initial suggestion follows the account's
  access. Changing the path only changes learning preferences, never permissions.
- Connection onboarding offers learning before collecting credentials. Only
  settings writers see its credential form. Saved credentials, a successful
  source read and checking a known record are separate setup milestones.
- **How this page works** is a closed native disclosure. It combines existing
  page guidance, relevant definitions and a link to practice. It never opens
  itself or blocks a work action. Staff pages use the same contextual help.
- Sales totals disclose their actual included source amounts and average
  calculation for the selected day. Stock, count variance, checkout receipts
  and estimated staff pay have definitions or calculation explanations beside
  the relevant work. Existing source, date, freshness and inclusion labels
  remain authoritative for each report.

## Lessons and practice

Each lesson contains task steps, a labelled fictional example, definitions,
a knowledge check with explanatory retry feedback, and a link to its real
workspace. Practice only updates the signed-in user's learning progress.
Completion is self-paced learning, not an access grant or staff certification.

Search matches permitted lesson text and glossary labels/definitions. Numeric
examples distinguish sales from deposits, shared stock from separate units,
on-hand from available, counted-minus-comparison variance, gross-pay estimates
and cash received from change. Example values are never mixed into real reports.

## Maintenance

- `LearningCatalog` owns lesson text, permissions, path prefixes, destinations
  and vocabulary. The most specific matching path chooses contextual training.
- `LearningExamples` owns the worked examples; every lesson needs one. Check
  example arithmetic and the underlying application behavior when changing it.
- `LearningJourney` owns path recommendations, completion and welcome dismissal.
  State is stored in the current user's `dashboard_config` under
  `learning_completed`, `learning_focus`, and `learning_welcome_hidden`.
  Updates lock the user; resetting dashboard layout preserves learning state.
- A reader can study a workflow without receiving write access. Lesson access
  is checked again on both GET and completion POST. Profile input cannot select
  another user, invent a path, or change account permissions.
- Keep essential instructions visible beside an action. Put optional definitions
  and examples in disclosures; do not add automatic tours or repeated popups.

Relevant checks are `test/integration/learning_flow_test.rb`,
`page_guide_flow_test.rb`, `dashboard_customize_test.rb`,
`onboarding_connect_test.rb`, and the operations/staff/retail workspace tests.
Build Tailwind after changing the views. Check the learning centre, a lesson,
an incorrect answer, completion, the path picker, glossary search and a closed
work-page guide in a browser, including a phone-width viewport.
