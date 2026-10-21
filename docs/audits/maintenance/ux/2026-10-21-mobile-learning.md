# Phone-width learning review — October 21, 2026

Continues maintenance task 07 against isolated `main` source `59cc99f3`, including
merged #213. The automation remains paused. All accounts, stock and records were
synthetic in a separate SQLite test database; production was not accessed. No
worker was started and no platform connection/read, payment or staff message was
requested. Browser network requests were restricted to the local audit server.

## Journey and role checks

Chromium rendered the welcome, learning index, introductory lesson and the
permitted work page at **320 × 812** and **375 × 812** CSS pixels for four roles:
admin, reader, inventory employee and employee. The three management roles used
Inventory; staff used the employee home. All 32 renders returned 200, with the
document scroll width equal to the viewport width. Inventory's contained,
horizontally scrolling tool navigation is intentional. The welcome screenshot
was visually reviewed, including wrapped path cards and the first-week checklist.

At 320 pixels, each role chose a permitted welcome path, saw a fitting tour
popover, closed it with Escape, submitted wrong introductory answers, read retry
feedback, corrected both answers and saw persisted lesson completion. Each role
opened help with `?`, searched lessons/definitions and closed help with Escape.
Admin had nine path choices, reader three, inventory employee two and staff
three. These choices did not grant permissions.

The admin setup lesson returned 200; the other three roles received 404 for that
unavailable lesson. The staff home did not offer the team-training link. Existing
Rails tests additionally check JSON filtering, team access and rejected preference
payloads. This pass found no reproducible UI defect requiring a source change.

## Checks

- Isolated SQLite Rails checks: 50 tests, 591 assertions, no failures/errors/skips
  across learning onboarding, lesson flow, definitions and connection onboarding.
- Browser-controller checks: nine tests covering tour progression/missing anchors,
  keyboard Escape/arrows, help search/text rendering and practice calculators.
- Tailwind and asset compilation succeeded before browser review.
- Browser journey assertions passed for all four roles at 320 pixels; 32 static
  viewport/role/page assertions passed across both widths.

This is source/fixture evidence. Actual mobile browsers, touch interaction,
screen-reader use, staff training and the operator's real data acceptance remain
open. Production deployment is recorded separately; this review did not deploy
or certify the newest source as running there.

Next iteration: a staff member uses the learning path and intended inventory or
hours workflow on their actual phone, with ordinary business approvals preserved.
