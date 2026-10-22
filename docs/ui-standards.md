# Rupert interface guidelines

One structure, one navigation, a handful of page templates, one voice. Every screen in the
management app is built from the pieces below and nothing else. The live catalogue of these
pieces is **System → Style guide** (`/system/style_guide`), rendered from the real CSS and
helpers, so what you see there is what a page gets.

This document is for whoever builds the next screen, human or agent: it says what Rupert's
interface is for, how to decide what goes where, and what every page must look and sound
like. Read §0 and §11 before writing a view; use §4–§8 while writing it; run §10 before
calling it done.

## 0. Philosophy

Rupert is the back office of a small retail business. The people using it are the owner,
a bookkeeper and a few staff, usually in the middle of something else: closing a register,
counting a shelf, matching a bank statement. The interface exists to let them finish that
one thing, see the state of the business at a glance, and trust the numbers.

- **Calm over clever.** A page is a quiet surface with one clear thing to do. No page opens
  with a wall of caveats, a strip of seven buttons, or three rows of navigation.
- **Everything has one home.** A page lives in one section and one group; a label is the
  same word everywhere; a colour means one thing. If two places say the same thing in
  different words, one of them is wrong.
- **Progressive depth.** The common path is on the surface. Everything else is one click
  away and out of sight until then: a `More` menu, a folded explainer, the `?` drawer, a
  collapsed rail. We never remove information; we fold it.
- **Numbers you can trust.** Money is tabular, right-aligned, with a real minus sign and a
  date range. A figure always says what it covers. Empty is a sentence, not a zero.
- **Built from templates, not from scratch.** Six page templates and one component set
  cover every screen. A new page chooses a template and fills slots; it inherits
  consistency instead of re-inventing it. Standardisation is a side effect of using the
  pieces, not a chore done afterwards.
- **Works everywhere the business happens.** Phone at the register, tablet in the stock
  room, laptop at the desk. Light, dark and the four appearances. Keyboard and screen reader.
- **Business first, sources second.** Rupert is the layer that makes sense of the day no
  matter which card processor, gateway, store platform, bank, backup or upload sits
  underneath, and those will change. Pages, sections and labels name the business concept
  (Daily close, Bank transactions, Stock, Deposits); the source (C-Trax, Shopify, Square,
  SwipeSimple, Authorize.net, QuickBooks, Google Drive) appears as a pill, a fact, a filter
  or a tab inside that page, never as the reason a page exists. Connecting a new source adds
  a connection card under System and a source value on existing pages, not a new section.
  Where a module is still named after a source (C-Trax daily close, SwipeSimple items, Square
  history) that is transitional: the target is one business page with the source as a tab.

## 1. Principles

1. **Simple by default, depth one click away.** A page shows the task and its primary action.
   Secondary actions sit in a `More` menu, filters fold into a toolbar, explanations fold into
   a disclosure, help lives in the `?` drawer. Nothing opens by itself.
2. **One place for each thing.** Navigation comes from `ModuleRegistry` only. Page titles come
   from `page_header` only. Colours come from the tokens in `application.css` only.
3. **Top down.** Shell → section → page template → components. A new page picks a template and
   fills its slots; it never invents layout.
4. **Say it once, the same way.** The same action has the same label everywhere (section 7).
5. **State is never colour alone.** A status pill, a flash and a step tracker each carry a word.

## 2. Structure

```
┌ top bar ──────────────────────────────────────────────────────────────┐
│ ☰  Rupert   [search /]                  Ask  Buzz  Sync  Bug  ?  (DO) │
├ rail ─────┬ main ─────────────────────────────────────────────────────┤
│ Overview  │ SECTION · GROUP                                           │
│ Sell      │ Page title                                   [More ▾] [+] │
│ Stock     │ One-line subtitle.                                        │
│ Bookkeep. │                                                           │
│  ├ group  │ (template body)                                           │
│  │ · page │                                                           │
│  │ · page │                                                           │
│ Reports   │                                                           │
│ …         │                                                           │
│ ‹ collapse│                                                           │
└───────────┴───────────────────────────────────────────────────────────┘
```

- **Top bar** (`.app-topbar`): menu button (phone/tablet), brand, global search, utilities,
  account. One row, always. Nothing page-specific lives here.
- **Rail** (`.app-rail`): the sections (`nav[aria-label="Module areas"]`). The current section
  is expanded and lists its pages in named groups (`nav[aria-label="Module"]`). On wide screens
  the rail is persistent and can be collapsed to icons (remembered per browser); under 1024px
  it becomes a drawer behind the menu button. Phones get the same drawer.
- **Main** (`main#main`): flashes, then the page. Width tiers: default `max-w-6xl` for tables and
  dashboards, `.page-medium` (56rem) for reading and settings, `.page-narrow` (42rem) for forms
  and short detail pages. No other `max-w-*` on page wrappers.
- **Page help** (`shared/workspace_help`): a quiet line under the page content, not above it.

Secondary navigation rows inside pages (`operations_navigation`, `retail_navigation`,
`time_navigation`) are gone: the rail covers every page they listed. In-page **tabs** (`.tabs`)
are only for views of the *same* record or report (Sales / Sales tax / Financial…), never for
moving between modules.

## 3. Navigation registry

Sections and groups are business activities, not systems. A source-specific page is a tab or
filter on the business page it feeds (see §0, "Business first, sources second").

`app/models/module_registry.rb` is the single source of truth: every reachable management page
is a module entry (or a sub-page of one), every module is in exactly one section, and each
section with more than six modules has named groups. Labels in the registry are the labels
everywhere (rail, page eyebrow, search, dashboard links). Sections follow the operator's day:

| Section | What belongs there |
| --- | --- |
| Overview | Dashboard |
| Sell | Sales, POS, daily closes, registers, customers |
| Marketing | Campaigns, influencers (feature-flagged) |
| Stock | Inventory, counts, transfers, materials, purchasing, catalog links |
| Bookkeeping | Overview, daily close, books & review, ledger & accounts, planning |
| Reports | Every report page |
| Work | Projects, tasks, goals, KPIs |
| Me | Personal receipts and hours |
| Team | Staff, users, time, schedule, leave, payroll, permissions |
| System | Health, connections, sync, uploads, settings, access, API, roadmap |

## 4. Page templates

Every page is one of these. The skeleton is the contract; the Style guide shows each one.

| Template | Use for | Skeleton |
| --- | --- | --- |
| **Overview** | A section's landing page | `page_header` → stat row (`.stat`) → work queues / cards |
| **List** | Records of one kind | `page_header` (primary: `Add X`) → `.toolbar` (search, filters, `Apply`) → `.card` table → pagination / `.empty-state` |
| **Detail** | One record | `page_header` (eyebrow: kind, title: name, `Edit`, `More`) → `.facts` → related sections as `.section-card` |
| **Form** | Add or edit | `.page-narrow` → `page_header` → `.card` with fieldsets → `.form-actions` (`Save`, `Cancel`) |
| **Report** | Figures over a period | `page_header` → `.tabs` (sibling reports) → `.toolbar` period picker → report table |
| **Settings** | Configuration | `.page-medium` → `page_header` → one `.section-card` per topic |

Rules that apply to all templates:

- Exactly one `h1`, rendered by `page_header`. The eyebrow is the section and group, filled in
  automatically from the registry; pass `eyebrow:` only to override.
- One primary button (`.btn-primary`) per page header, at most. Everything else is `.btn-ghost`
  or lives in the `More` menu (`page_header ... menu: [[label, path], …]`).
- Section headings are `h2.section-title`; card headings are `h3.card-title`.
- Lists and tables have an empty state that says what is missing and the one thing to do.
- Long explanations use `fold_explainer` or a `<details class="explainer">`; the lead sentence
  stays visible.

## 5. Components (CSS classes)

| Class | Purpose |
| --- | --- |
| `.card`, `.card-pad`, `.section-card`, `.card-head`, `.card-title` | Surfaces and their headings |
| `.stat`, `.stat-label`, `.stat-value`, `.stat-value-sm` | Figures that matter |
| `.toolbar`, `.toolbar-field`, `.field-label` | Filter/search row above a table |
| `.table`, `.th`, `.td`, `.num`, `.empty-row` | Data tables |
| `.facts`, `.facts dt/dd` | Key–value summary on a detail page |
| `.tabs`, `.tab` | Views of the same record or report |
| `.btn-primary`, `.btn-ghost`, `.btn-danger`, `.btn-sm`, `.btn-lg` | Buttons (one primary per header) |
| `.menu`, `.menu-item` | The `More` overflow menu (`<details>` based) |
| `.input`, `.select`, `.search`, `.checkbox` | Form controls |
| `.form-actions` | Save/Cancel row at the end of a form |
| `.pill-*` | Status: `fern` done/positive, `clay` attention, `rose` problem, `olive` info, `taupe` neutral |
| `.flash-notice`, `.flash-alert` | Result of an action |
| `.empty-state`, `.empty-state-title`, `.empty-state-hint` | Nothing here yet |
| `.explainer` | Folded explanation |

Add a component by adding it here, to the stylesheet and to the Style guide, in that order.

## 6. Colour, type, spacing

- **Colour** lives in `web/app/assets/tailwind/application.css` `@theme` plus the appearance
  blocks (Herbal default, Light, Mist, Sepia, Dark). Views use token classes (`text-ink`,
  `bg-paper`, `border-fog`, …), never hex. Every text/background pair meets WCAG AA; run
  `web/bin/check-palette-contrast` after changing a token. Research behind the family: adults
  prefer blues/greens and dislike dark yellows and browns (Palmer & Schloss 2010); low
  saturation reads as calm (Valdez & Mehrabian 1994); similar hues with strong lightness
  contrast are most harmonious (Schloss & Palmer 2011).
- **Type**: display serif for `h1`/`h2`/stat values; system sans for everything else.
  Sizes: page title `text-2xl/3xl`, section `text-xl`, card title `text-lg`, body `text-sm`,
  caption `text-xs`. No bracketed pixel sizes (`text-[10px]`).
- **Radius** tokens: `--radius-control` (buttons, inputs) `.75rem`, `--radius-card` `1rem`,
  `--radius-pill` `999px` (status pills, rail items). Use `rounded-control`/`rounded-card`.
- **Spacing**: page sections `space-y-6`; inside a card `space-y-4`; toolbar gap `gap-3`.
- **Motion**: 150–200ms, respects `prefers-reduced-motion`.

## 7. Verbiage

- **Case**: sentence case everywhere (titles, buttons, labels, tabs). Proper nouns keep
  their case (C-Trax, Shopify, Square, QuickBooks, Google Drive).
- **Page titles**: the thing, not the action: `Customers`, `Inventory`, `Expenses`. Forms:
  `Add customer`, `Edit customer`. Details: the record's name. Never `New customer`.
- **Verbs** (one per intent):

  | Intent | Use | Not |
  | --- | --- | --- |
  | create a record | `Add` | New, Create, Record |
  | change | `Edit` | Update, Modify, Change |
  | persist a form | `Save` | Submit, Update, Apply |
  | drop changes | `Cancel` | Back, Discard, Close |
  | go to a record or page | `Open` | View, See, Show, Go to |
  | get a file | `Download CSV` / `Download PDF` | Export, Print PDF |
  | print | `Print` | |
  | run a filter | `Apply` | Filter, Refresh, Update view, Find |
  | pull from a source | `Sync now` | Refresh, Pull, Import |
  | remove softly | `Remove` | Delete (reserve for permanent) |
  | work a queue | `Review` | Check, Inspect |
  | accept | `Approve` / `Reject` | |
  | more actions | `More` | Actions, Options, Tools |

- **Navigation back** is the rail or the browser, not a `Back` button. A form's `Cancel` returns
  to where it came from.
- **Status words**: `Draft`, `Open`, `In review`, `Approved`, `Posted`, `Void`, `Locked`,
  `Done`, `Overdue`, `Needs attention`. One pill per status.
- **Empty states**: "No customers yet." + "Add your first customer." Never "No data".
- **Dates**: `Oct 21, 2026`; times `3:40 PM`; ranges `Oct 1 – Oct 21, 2026`. Money:
  `$1,234.56`, tabular, right-aligned, red only for negatives with a real minus sign.
- **Subtitles** are one sentence, no trailing jargon. Caveats go in an explainer.
- **Source names** are the brand: C-Trax, Shopify, Square, SwipeSimple, Authorize.net.

## 8. States

- Busy: the submit button shows `Saving…`/`Syncing…` (Turbo `data-turbo-submits-with`).
- Result: a flash at the top of main; success in notice, failure in alert; one sentence.
- Empty: `.empty-state` with the one next action.
- Error on a field: `aria-invalid` + the message under the field; the form keeps its values.
- Loading a slow region: a quiet caption `Loading…`, never a layout jump.

## 9. Accessibility and devices

- Keyboard: every control reachable; visible focus ring; `/` search, `?` help, `Esc` closes.
- Touch: 44px targets on coarse pointers; 16px inputs on phones.
- Landmarks: `header`, `nav` with labels, `main#main`, one `h1`.
- Contrast and colour-vision safe pairs; tables keep headers in view while scrolling.

## 10. Page checklist

Before a page is done:

1. It is one of the six templates and uses `page_header`.
2. Its registry entry exists with the final label, section and group.
3. One primary action; the rest in `More`.
4. Labels follow the verb table; sentence case throughout.
5. It has an empty state and (for forms) field errors.
6. It renders in Herbal and Dark, at 375px and 1440px, without horizontal scroll.
7. No `max-w-*` on the wrapper beyond the width tiers; no pixel font sizes; no hex colours.

## 11. How to approach a new screen

Work top down. Answer each question in order; the answers decide the markup.

1. **Where does it live?** Pick the section and group from §3. Add the registry entry
   (`ModuleRegistry::ENTRIES` + the section's `modules`/`groups`) with the final label before
   writing the view. If it is a sub-page of an existing module (a record, a form), it has no
   entry: the parent module is its home and the rail highlights the parent.
2. **Which template?** One of the six in §4. Ask what the person is doing: looking at a
   section (Overview), finding a record (List), understanding one record (Detail), entering
   data (Form), reading figures over a period (Report), configuring (Settings). A page that
   seems to need two templates is two pages, or a Detail page with sections.
3. **What is the one action?** That is the primary button. Everything else is `More` or a
   ghost button inside the relevant section. If there is no action, there is no primary.
4. **What must be on the surface?** The title, one sentence, the figures or rows that answer
   the person's question, the primary action. Caveats, definitions, methodology, history and
   rarely used controls go one click deeper (`fold_explainer`, `details.explainer`, `More`,
   the `?` drawer via `PageGuides`).
5. **What are the states?** Empty (what is missing + the next action), busy (button label),
   error (field message or alert flash), done (notice flash). Write them before the happy path.
6. **What words?** Titles name the thing. Buttons use the verb table in §7. Statuses use the
   status words. Sentence case. One sentence per subtitle.
7. **Render it in the style guide's company.** Open System → Style guide next to the new page
   in Herbal and Dark, at 375px and 1440px. If a piece on the page is not in the style guide,
   either use one that is, or add it to §5, the stylesheet and the style guide first.

### Where things go, at a glance

| Thing | Goes |
| --- | --- |
| Moving between modules | The rail (from the registry), never links inside a page |
| Views of the same record or report | `.tabs` under the page header |
| The page's main action | One `.btn-primary` in `page_header` |
| Second-tier actions (download, print, sync, remove) | `menu:` on `page_header` |
| Actions on one row or card | `.btn-ghost.btn-sm` inside that row or card |
| Search and filters | One `.toolbar` directly above the table |
| Key figures | A `.stat` row directly under the header |
| What a figure means | `define(term)` beside the label, or a folded explainer |
| Explanations and caveats | `fold_explainer` / `details.explainer` after the content they explain |
| How the page works, tours, lessons | The `?` drawer and the page-help line at the bottom (`PageGuides`, `PageTours`) |
| Results of an action | A flash at the top of main |
| Something missing | `.empty-state` / `.empty-row` with the one next action |
| Configuration for a module | A Settings-template page in System, or a `More` → `Settings` link |
| Record metadata (ids, dates, source) | `.facts` at the top of a Detail page |
| Related records | A `.section-card` per relation, below the facts |

### Anti-patterns (seen in the old UI; do not reintroduce)

- A second or third navigation row inside the page body.
- A different label for the same page in the rail, the title and a link.
- Five to seven ghost buttons under a title.
- Opening paragraphs that explain what the page is not.
- Pixel font sizes, hex colours, ad-hoc `max-w-*` wrappers, `rounded-full` inputs.
- Colour as the only carrier of a state.
- `View`, `See`, `Show`, `New`, `Record`, `Export`, `Refresh`, `Back` as button labels.

## 12. Changing the system itself

- **A new component**: add it to §5, to `web/app/assets/tailwind/application.css` (tokens
  only), and to `web/app/views/style_guide/show.html.erb`, then use it.
- **A new section or group**: `ModuleRegistry` only. The rail, eyebrows and tests follow.
- **A colour change**: the `@theme` block and every appearance block, then
  `web/bin/check-palette-contrast`. Cite the reason in the comment.
- **A new template**: §4 first, then an example in the style guide, then the first page.
- Tests that pin the structure live in `web/test/integration/compact_navigation_test.rb`,
  `module_nav_test.rb`, `page_header_pages_test.rb` and `web/test/models/module_registry_groups_test.rb`.

## 13. Future directions (agreed with the owner, not yet built)

These extend the same backbone. Build them from the registry and the templates, not beside them.

- **Sections drive more than navigation.** `ModuleRegistry` sections are the one list of
  what the business does. The same list should drive page guides (`PageGuides`), lessons
  (`LearningCatalog`), and the Buzz team chat: one channel per section
  (`#bookkeeping`, `#sell`, `#stock`, `#team`, …) with a persona file per section
  (`config/buzz_agent/<section>.md`) so the bookkeeping channel answers like a bookkeeper
  and the team channel like an HR lead, on top of the general Rupert persona.
- **Training as its own section.** Schedules (annual to-dos, recurring courses), assignments
  and completion tracking, where Rupert's own onboarding lessons are the first course: use
  Rupert to train on Rupert and monitor it in Rupert. Today's pieces (Learn Rupert, Training
  progress) are the seed.
- **Source consolidation.** Replace source-named modules (C-Trax daily close, SwipeSimple
  daily close, SwipeSimple items, Square history, C-Trax history, QuickBooks import) with one
  business page each and the source as a tab or filter (§0, business first).
- **Reports and money as the showcase.** Cash flow, statements, forecasts and projections are
  where the owner looks every day; they get the most design effort, the richest charts and the
  clearest explanations of any screens in the app.
