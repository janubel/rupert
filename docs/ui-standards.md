# Rupert UI standards

One structure, one navigation, a handful of page templates, one voice. Every screen in the
management app is built from the pieces below and nothing else. The live catalogue of these
pieces is **System → Style guide** (`/system/style_guide`), rendered from the real CSS and
helpers, so what you see there is what a page gets.

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
