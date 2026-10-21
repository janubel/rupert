# Payments in plain English

Reviewed 2026-10-15. Rupert can be the place staff manage a sale, stock and receipts while specialist payment providers handle the card transaction. Connecting those providers is different from becoming a payment processor.

## Who does what?

| Role | What it does for the shop |
| --- | --- |
| Checkout or POS | Builds the sale: items, totals and the request to pay. Rupert is being developed for this role. |
| Gateway | The secure connection that passes the payment request from checkout to the processing system and returns its response. Authorize.net is one example. |
| Processor | Runs the systems that route card transactions between the shop's payment arrangement, card networks and banks, including work needed for clearing and settlement. |
| Card network | Visa, Mastercard and other networks carry transaction messages and set their network rules. |
| Customer's bank | Issues the card and approves or declines the payment. |
| Acquiring bank | Supports the shop's card-acceptance arrangement and settlement. It is a separate role from the customer's bank; it may also differ from the bank holding the shop's everyday checking account. |

**Typical card approval path: checkout → gateway → processor / acquiring arrangement → card network → customer's bank.** The approval or decline returns to checkout. This is a simplified request path, not a diagram of where money is held. One company can supply several roles. See [Stripe's explanation of gateways and processors](https://stripe.com/resources/more/payment-processor-vs-payment-gateway).

**Approved does not mean deposited.** Authorization approves an amount; capture submits the approved charge for completion, and settlement follows. A bank deposit can reflect fees, refunds and other adjustments. See [Authorize.net's payment-flow explanation](https://www.authorize.net/resources/how-payments-work.html).

SWIFT is a secure financial messaging network commonly used for international bank payments. It does not itself move money, and it is different from the ordinary Visa/Mastercard checkout route above. See [SWIFT's own explanation](https://www.swift.com/about-us/who-we-are/what-swift).

## Is a processor software or a company?

Both descriptions can appear: software does the technical processing, while a company operates the service under agreements with its payment partners. Installing that software does not give Rupert those relationships. It also does not automatically transfer all of a shop's responsibility for disputes, refunds or fraud to the provider; the merchant agreement determines the responsibilities.

## Could Rupert be our own gateway?

We can build Rupert's checkout and connections to a gateway. That lets us control the staff experience without replacing the underlying payment service.

Operating an independent gateway is possible, but it is a separate undertaking: approved processor/acquirer connections, integration testing, secure operations and ongoing support. It still needs payment partners. [Visa's acquirer implementation guide](https://developer.visaacceptance.com/docs/vas/en-us/payments/acq/all/na/payments-acq.html) illustrates the banking and processor configuration behind a connection. [PCI DSS](https://www.pcisecuritystandards.org/standards/pci-dss/) applies to relevant entities that store, process or transmit card data, or can affect its security. The exact obligations depend on the design and payment partners.

The current plan is to connect Rupert to the merchant's confirmed, approved providers. Rupert is not currently operating an independent gateway or processing service.

## Where Valmar and Authorize.net fit

The business reports using Valmar for its payment services. Valmar calls itself a processor and identifies itself as a registered merchant-services partner (ISO/MSP) for banks. Its public site also advertises gateway services. That does not identify which gateway, backend processor or bank serves Derrick's particular account. See [Valmar's official site and disclosures](https://vlmr.com/).

Authorize.net is a possible gateway for that account, not a confirmed connection. Ask Valmar first. There may already be an account that Rupert can connect to; do not assume two new subscriptions are needed.

## Deep Run Hemp's separate NMI history

Emails reviewed October 16, 2026 show a separate arrangement for Deep Run Hemp: Next Stage Payments confirmed merchant approval on July 21, supplied WooCommerce/NMI integration guidance on July 22, and matching gateway/store receipts demonstrate a completed NMI card sale on July 23. The store confirmation explicitly names "Credit Card (NMI)". NMI checkout therefore worked for at least one historical store sale; the emails do not establish current availability, bank settlement or a completed Rupert integration.

Next Stage was the account approval and integration support contact in those emails. This does not confirm Next Stage's backend processor/acquiring bank or establish that Deep Run Hemp used the Valmar/Authorize.net arrangement discussed above. For the application-document limits, setup requirements, source chronology and remaining verification, see [Deep Run Hemp's historical NMI evidence in the payment setup guide](https://techmore.github.io/rupert/payment-integrations.html).

## Who to contact

Public contact details checked 2026-10-15. These are company contacts, not a verified account representative for the shop.

**Valmar Merchant Services — start here.** Call **1-866-825-6271** ([official website and contact number](https://vlmr.com/)), or open the [client login](https://app.valmarpayments.com/). Ask which gateway, backend processor/acquiring bank and terminal application serve the existing business, and who supports integrations.

**Authorize.net — if Valmar confirms this gateway.** Existing-account support: **1-877-447-3938**, [support and chat](https://www.authorize.net/support.html), [merchant login](https://login.authorize.net/). Ask about account access, permitted integration methods, test setup and supported payment features. New-account sales: **1-888-323-4289**, [contact form](https://www.authorize.net/contact-us.html). Use existing-account support before considering a new account.

## A useful request to Valmar

**Please confirm the payment setup already serving our business:** gateway name; backend processor and acquiring bank; merchant account/reference; enabled in-store and website channels; supported PAX model and installed payment application; approved integration documentation and test access; tipping/refund support; and how daily batches match bank deposits. Please identify our account support contact and any integration or recurring fees.

Record their answers, support contacts and review/renewal dates in Rupert's [private owner checklist](https://herbalhealers.rupertpos.com/owner_checklists). Use the vendor's secure channel for account verification and the approved credential form for API secrets. The checklist stores references, not passwords.

## What Rupert can claim today

Implementation scope reviewed October 17, 2026: Rupert now includes cash checkout with tax checks, confirmed customer tips and receipts; optional per-store Authorize.net hosted-card checkout with uncertain-outcome recovery; and NMI sandbox-only card testing. NMI production charging is blocked. Provider preparation/read checks, reporting and the legacy warehouse checkout are separate paths. These implemented features do not demonstrate that Derrick's intended merchant account is connected or that real payments, stock effects, terminals, refunds and bank settlement have passed acceptance. Keep the existing accepted checkout as the fallback until the [cutover checks](https://techmore.github.io/rupert/pos-parity.html) pass.

See [payment account setup](https://techmore.github.io/rupert/payment-integrations.html) for the separate setup/check paths and [daily-use rollout](https://techmore.github.io/rupert/day-to-day-readiness.html) for what still needs acceptance. Public contact details above retain their stated verification date.
