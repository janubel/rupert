# Onboarding and learning in Rupert

Open **Learn Rupert & definitions** from the account menu or staff footer, or
press **?** on any page. The learning centre is at `/learning`; it is available
to every signed-in, active workspace account. Public documentation grants no
application access.

## The first visit

- A new account sees a **welcome card** on its home page (dashboard or My time)
  asking one question: *What will you mostly do here?* Each answer is a learning
  path with a short description and total minutes. Choosing one records the path
  and opens the home page with the one-minute tour; **Skip for now** records the
  skip. Neither changes permissions. The standalone version lives at `/welcome`
  and can be reopened from Learn Rupert (**Restart the welcome**).
- After the welcome, a **Your first week** checklist replaces the card until it
  is finished or hidden. Items are role-aware and many tick themselves from real
  workspace state: a chosen path, the home-page tour, a finished lesson, a saved
  source connection, a successful sync, a second account, a customised dashboard,
  a finished path. The rest (check a day of sales, open the review queue, clock
  in, open the register) have **Mark done**. **Hide** removes it from the home
  page; **Show on my home page** in Learn Rupert brings it back.

## Help where the work is

- **How this page works** stays a closed native disclosure in the help bar. It
  combines the written page guide, relevant definitions, the page tour as a
  numbered list, and a link to practice. It never opens itself.
- **Show me around** starts a **guided tour** of the real elements on the page
  (`PageTours`). Steps are anchored with `data-tour="…"` attributes; steps whose
  anchor is not on the page for this person are skipped. Tours never start by
  themselves: a person starts one from the help bar, the help panel, the
  checklist, or by arriving with `?tour=1` after choosing it. Finishing or
  skipping records the tour for the account and removes the **New** badge.
  Tours are keyboard operable (arrows, Escape, focus stays in the popover) and
  honour reduced motion.
- The **? help panel** (header button or the `?` key) shows this page's guide
  summary, its tour and lesson, live search across lessons, definitions and
  tours (`GET /learning.json?q=`), quick links and keyboard shortcuts. Without
  JavaScript the button is a link to Learn Rupert.
- **Definitions** sit beside labels as a small `?` mark (`define('term')` in a
  view). Opening one shows the same wording used in the glossary, with a link to
  all definitions. They are native disclosures positioned as popovers.
- **How is this calculated?** disclosures (`explain_calculation(...)`) show the
  page's own live numbers step by step: today's sales by source on the dashboard,
  cover and suggested reorder on Alerts, estimated gross pay on My time, sales
  totals and averages on Sales, and others across Stock and Money pages. Values
  always come from the data already on the page; nothing is invented.

## Lessons and practice

Each lesson has task steps, **common mistakes**, a labelled fictional example,
definitions, one or more **knowledge checks** (every question must be right in
one submission; wrong answers show their explanation for retry), and a link to
the real tool, with **Open with the tour** when a tour exists for that page.
Numeric lessons add **Try it with your own numbers**, a small calculator for
variance, cash change, average sale, or days of cover and suggested reorder.
Practice only updates the signed-in user's learning progress. Completion is
self-paced learning, not an access grant or staff certification.

Paths group lessons into modules: set up my workspace, serve customers, look
after stock, understand sales and close the books, run the team, organise
projects and goals, find my tasks, manage my hours and receipts. Finishing every
lesson in a path shows a **module complete** badge. Lessons cover: finding your
way around, workspace setup, keeping sources fresh, giving the right access,
the register, customer records, your hours and receipts, stock, counts, alerts,
sales totals, reports, closing a day, reviewing hours, reviewing receipts,
assigned tasks, and projects and goals. Each lesson is permission-checked on
read and on completion.

**Team training progress** (`/learning/team`, for accounts with `users.read` or
`hr.read`) lists each account's path, lessons done, tours taken and last lesson.
It is read-only and makes no changes.

## Maintenance

- `LearningCatalog` owns lesson text, permissions, path prefixes, destinations,
  knowledge checks (`question…` plus optional `questions:`), `mistakes:`,
  `practice:` and the vocabulary (`TERMS`). The most specific matching path
  chooses contextual training.
- `LearningExamples` owns the worked examples; every lesson needs one. Check the
  arithmetic against the real service (for example `RestockAdvisor`).
- `PageTours` owns tours: key, title, intro, path prefixes, permission and
  steps. Views add anchors with `tour_anchor('key')` (or `data: { tour: 'key' }`
  on Rails helpers). Keep anchors on stable wrappers; never change layout.
- `PageGuides` owns the written page guides and the path map.
- `GettingStartedChecklist` owns the first-week items and their detection.
- `LearningJourney` owns path recommendations, completion, tours, welcome and
  checklist state. State is stored in the current user's `dashboard_config`
  under `learning_focus`, `learning_completed`, `learning_completed_at`,
  `learning_welcome_hidden`, `learning_welcomed_at`, `learning_tours`,
  `learning_checklist_done` and `learning_checklist_hidden`. Updates lock the
  user; resetting dashboard layout preserves learning state.
- Profile input cannot select another user, invent a path or tour, or change
  account permissions. A reader can study a workflow without receiving write
  access.
- Keep essential instructions visible beside an action. Put optional
  definitions, calculations and examples in disclosures. Tours and the help
  panel are always started by the person.

Relevant checks: `test/integration/learning_flow_test.rb`,
`learning_onboarding_test.rb`, `learning_definitions_test.rb`,
`page_guide_flow_test.rb`, `dashboard_customize_test.rb`,
`onboarding_connect_test.rb`, `test/services/page_tours_test.rb`, and the
browser-controller tests `test/javascript/tour_test.mjs`,
`help_panel_test.mjs`, `practice_test.mjs`. Build Tailwind after changing the
views. In a browser, check the welcome, choosing a path, the dashboard tour
(including Escape and keyboard), a `?` definition popover, a calculation
disclosure, the help panel search, a lesson with a calculator, a wrong answer,
completion, the team view and a phone-width viewport.
