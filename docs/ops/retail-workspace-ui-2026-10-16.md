# Retail workspace interface

The cashier, receipt, native C-Trax daily review and Rupert register screens
share the existing Rupert interface and role-aware retail navigation. Employees
retain checkout and personal-workspace access; financial review and register
administration remain restricted by the existing server permissions.

The catalog uses compact product cards, unique quantity labels, visible stock
freshness and an accessible phone cart shortcut. The customer screen retains
private, unselected tip choices. Cash and card actions use specific labels.

Daily review separates source sales, tax, tips, tender evidence and register
cash. Missing amounts remain Unknown, native source currencies are shown, and
local review is explicitly distinct from source-register closing and bank
settlement. Source timestamps include timezone labels.

Opening a Rupert register posts the controller's expected field scope and the
Rupert location ID. Closing asks for an unfilled physical count in dollars;
server-side exact decimal parsing rejects blanks, negatives and fractional
cents. Strict integer cents remain supported for existing callers. Outstanding
checkout guards and payment deduplication are unchanged.

Validation covers financial totals, role boundaries, register form submission,
invalid cash counts, optional cart targets and tender action labels. Browser
verification uses read-only live pages; no live payment or register-close action
is required to verify the interface.
