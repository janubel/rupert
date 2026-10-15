# Private owner checklists

Reviewed 2026-10-15. The owner checklist records a store administrator's setup facts, contacts, evidence and acceptance decisions inside the signed-in Rupert application. The public roadmap and this guide describe the workflow; they do not contain the store's private checklist values.

## Access and purpose

Use the signed-in **System → Owner checklists** page with an active store administrator account. Access is based on the administrator role, not delegated settings permissions. The private page, history and print view remain scoped to the selected store. A platform super-admin must first select the intended store.

A checklist is an owner attestation, not an automated test result, vendor approval, merchant verification or permission to deploy. Record what was actually inspected and tested. A saved pass does not enable a planned feature, execute a payment, change a platform SKU or stock quantity, or override an approval requirement.

## Record facts and follow-ups

Give each private checklist a name, a domain, its purpose and the responsible owner's name, optional email and optional phone. The domain is a recorded setup fact; saving it does not configure DNS, hosting, TLS or account access.

Then record each service's name and purpose, renewal/review cadence, actual next renewal and review dates, support contact name/email/phone, observed MFA status, ordinary login shortcut and a vault record label. The vault label identifies where credentials are managed; it does not contain or grant access to them. Recording MFA status does not configure MFA. Each checklist supports up to 20 services, including archived services.

Use the actual dates and cadence supplied by the owner or vendor. Leave unknown dates unconfirmed rather than inventing a renewal interval, approval date or expiry. Cadence labels do not calculate the next dates. Reminder dates are local manual follow-ups; the checklist does not schedule email, send messages or notify a vendor.

Archive a service when it no longer belongs in active setup work. Its private record and audit history remain retained. Archiving does not cancel a subscription, disconnect a provider, revoke credentials or delete the vendor account.

Store passwords, payment-card data, API keys, access tokens and transaction keys in the appropriate credential/secret workflow, not in checklist notes, contact fields or evidence. Existing provider credentials stay in **POS & payments** or their established connection form. The checklist offers no credential fields and cannot determine whether arbitrary free text contains an undisclosed secret.

## Review implemented scope

Review each feature against the current catalog's implementation status, scope and acceptance limits. A feature pass requires recorded evidence and an actual test/review date. Planned functionality cannot be marked passed. Partial functionality can be accepted only within its stated implemented scope; accepting a quote preview does not establish payment capture or a production POS cutover.

A changed feature definition or newly introduced scope requires renewed review. If the catalog changes while a feature review form is open, saving that old scope is rejected; read the current scope before confirming it again. Historical decisions remain historical evidence; they cannot silently become proof for a new implementation. Recheck assumptions after account, terminal, configuration or deployment changes even when the catalog text is unchanged.

Do not invent test outcomes or dates. Evidence should explain the scenario checked, observed result and remaining limitation, in the freeform feature evidence note. Feature evidence is text, not an automatically fetched or validated document link. The checklist records that account's owner's decision; separate automated test, deployment and vendor evidence must still support their respective claims.

## Ordinary login shortcuts

The service login URL accepts a restricted HTTPS address for the ordinary vendor login page. The syntax check rejects query parameters, user information, fragments, IP literals, nonstandard ports and recognized local host suffixes. It does not resolve DNS or establish that a public-looking hostname points to a public network. Rupert does not fetch the login page, inspect its contents or verify the site's ownership or availability.

Use a clean ordinary login address rather than a signed download, login callback or URL containing credentials. Keep account and document access controls at their host. Opening a link is an explicit browser action; a saved URL is not an integration or an account-access check.

## Saving and history

Save after reviewing the proposed values. Concurrent edits use a version check: a stale form must be reloaded and reviewed instead of overwriting another administrator's change. A successful save atomically records an immutable application event with the affected section's before/after values, actor and time. The page shows the latest 20 update summaries. Earlier events remain stored; history does not make an earlier decision a current pass or provide a full historical-version export.

Checklist payloads and their history are encrypted in Rupert's database. This applies to recorded contacts, notes and reference links; it is not a promise that a signed-in display, browser memory, printout or external document is encrypted. Protect the application's encryption keys and database backups through the established operations process.

## Private printing

Use the authenticated print view only on a trusted device. It prints the current checklist and available recent event summaries, not every historical version. Its self-contained HTML does not load external fonts, scripts or images. It contains private store data and remains subject to the same administrator/store boundary. Browser print preview, downloaded PDFs, printer queues and paper copies leave Rupert's encrypted database protection.

Review the output before sharing it, choose its audience and protect or dispose of copies appropriately. Printing does not publish to GitHub Pages and does not grant the recipient application access. No checklist contacts, evidence notes or historical values belong in the public roadmap, source repository or release receipt.

## Operational boundaries

The checklist provides local records and manual follow-ups. It does not fetch reference sites, test vendor accounts, renew credentials, schedule messages, operate terminals, collect payments or deploy the application. A pass represents the recorded implemented scope and owner evidence, not full readiness for every workflow.

See [POS and payment setup](https://techmore.github.io/rupert/payment-integrations.html), [POS cutover acceptance](https://techmore.github.io/rupert/pos-parity.html) and [inventory workflows](https://techmore.github.io/rupert/inventory-workflows.html) for their independent acceptance and safety limits.
