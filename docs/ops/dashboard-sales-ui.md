# Dashboard sales and shared workspace UX

The dashboard includes native C-Trax completed, nondeleted orders alongside paid,
fulfilled and refunded canonical order history. USD order totals include recorded
tax and shipping, exclude tips, and show sales before separate refund review.
Only canonical selling sources are accepted. Ledger, gateway, SwipeSimple,
invoice, NMI sandbox and NAB deposit observations never contribute to sales.

C-Trax remains in its encrypted store/day snapshots. The view does not insert a
second canonical order. Native identity is API origin, store ID and order ID;
repeated IDs use the newest snapshot once. Conflicting business dates, missing
amounts, unreadable timestamps or other currencies are excluded with visible
coverage warnings. Each timestamp must belong to its stored business day in the
store timezone. Display and chart boundaries use Rupert's business timezone.

Today is local midnight through the current request time. Yesterday is the whole
previous calendar day. Seven and thirty day windows include today. Cards, source
breakdowns and charts share one request-local sales snapshot. C-Trax reads do not
need a Shopify catalog sync to invalidate a cached dashboard fragment.

Source cards distinguish last successful pull, latest stored sale and C-Trax
business date. C-Trax stock and sales timestamps are separate. Square is shown
even when its newest stored order is old. A zero count means no imported orders,
not certified absence of activity. Payments, deposits and recovery backups carry
explicit evidence labels. Their schedules and actions use native disclosures.

The order journal remains a canonical-order workspace, with links explaining
where native C-Trax sales are reviewed. Its charts use canonical sale history.
The dashboard provides permission-filtered daily POS, close, reconciliation and
personal time shortcuts. Employee and management shells share typography, focus
styles, touch targets and navigation treatment. Employee permissions and personal
record isolation are unchanged.

Layout customization uses one enclosing Stimulus controller, keyboard-operable
reordering, change events for visibility, an accessible expanded state, CSRF
protection and duplicate-save prevention. Dashboard source polling runs every
thirty seconds, skips hidden tabs and overlapping requests, and retains open
source disclosures while refreshing. Sales cards and charts refresh in place after source reads;
custom layout and disclosure state are preserved. The default layout places
sales trends before exceptions and hides the duplicate stock-alert history;
saved layouts and explicit widget choices remain available.

## Verification

- Exercise mixed canonical/C-Trax sales, duplicate native IDs, currencies,
  refunds, tips, payment mirrors, DST boundaries and workspace isolation.
- Confirm a C-Trax snapshot update appears without a catalog sync.
- Check dashboard, source refresh, navigation and employee permissions.
- Open, reorder, hide, save and restore a dashboard layout with the keyboard.
- Inspect desktop and phone layouts, chart/card totals, source timestamps and
  employee preview. Do not create a sale, charge a card or alter source stock
  while verifying UI changes.
