# Grocery API integration candidates

Research pass on other grocery chains that expose a product-search API, a
cart / cart-link API, or an affiliate link program comparable to what this
meal planner already integrates with:

- **Kroger** — official OAuth developer API (Products, Locations, Cart).
  Product search and "send to cart" both hit Kroger's own endpoints; the
  household authenticates once via browser and the token is used for search
  and cart writes.
- **Walmart** — product search against walmart.com's public catalog, plus a
  cart *link* (no account/OAuth needed) that opens a prefilled Walmart cart
  in the browser for a chosen store.

Ranked below are the closest analogues found, from best fit to no real path
today. "Fit" means: does it offer first-party product search, a way to get
items into a cart (API or deep link), and is it reachable without a
retailer-side sales relationship.

## Ranked candidates

### 1. Instacart Developer Platform (Connect API)

The strongest candidate by far, and arguably higher-value than a single new
chain: one integration reaches Instacart's **1,800+ retail banners**,
including several chains below that have no API of their own (Publix,
ALDI, Costco, Wegmans, Sprouts, and regional H-E-B markets among them).

- Product/catalog search, recipe-ingredient matching, and cart-building
  endpoints are all first-party and documented.
- Each retailer keeps its own cart/checkout inside Instacart (multi-retailer
  orders don't merge into one cart), which matches this project's per-store
  shopping-list model reasonably well.
- Developers with a live integration can become affiliate partners and earn
  commission on orders/sign-ups originating from their app — a bonus on top
  of the shopping functionality itself.
- Downsides: requires an approval process (roughly 30–40 days from request
  to production key, per Instacart's docs), a compliance review, and an
  Enterprise Help Desk / Tastemakers account for commission tracking. Not a
  same-day self-serve signup like Walmart's cart-link approach.

Sources: [Instacart Developer Platform announcement](https://www.instacart.com/company/updates/the-instacart-developer-platform-a-new-way-to-turn-inspiration-into-action), [Instacart Developer Platform docs](https://docs.instacart.com/developer_platform_api), [Connect API docs](https://docs.instacart.com/connect), [Approval process](https://docs.instacart.com/developer_platform_api/guide/concepts/launch_activities/approval_process)

### 2. Sam's Club (SAM's Advertising Partners / SBA API)

Sam's Club has stood up an official developer portal
(`developer.samsclub.com`) with a **Catalog Item Search** endpoint, and runs
an affiliate program through Rakuten Advertising for link-based commissions.

- Worth tracking, but the current API surface reads as built for
  advertisers/sellers (campaign bidding, catalog search for ad targeting)
  rather than a consumer shopping-cart flow — there's no confirmed
  "add to cart" or cart-link endpoint for third-party apps yet.
- A membership requirement (unlike Walmart) is also a real constraint for
  households without a Sam's Club membership.

Sources: [SAM's Advertising Partners](https://developer.samsclub.com/), [Catalog Item Search](https://developer.samsclub.com/API/catalog-item-search/), [Sam's Club affiliate program](https://getlasso.co/affiliate/sams-club/)

### 3. Amazon (Fresh / Whole Foods via Product Advertising API + Associates)

Amazon's Product Advertising API is official, mature, and includes an
"Add to Cart" form that deep-links a set of items into an Amazon cart with
affiliate attribution (up to 15% referral fees via Associates).

- Well documented and self-serve to apply for, similar in spirit to
  Walmart's affiliate-style cart link.
- The catch: it's scoped to Amazon's general catalog. There's no confirmed
  first-party API specific to **Amazon Fresh or Whole Foods** grocery
  inventory/pricing (which vary by delivery zone), so grocery-specific
  product search would be unreliable through this API even though the
  cart-link mechanism itself would work.

Sources: [Amazon Product Advertising API](https://en.wikipedia.org/wiki/Amazon_Product_Advertising_API), [Add to Cart form docs](https://webservices.amazon.com/paapi5/documentation/add-to-cart-form.html), [AWS re:Post — API for Amazon Fresh/Whole Foods?](https://repost.aws/questions/QUAWoPILDhS_6j458Ih6zAzQ/is-there-an-api-for-amazon-fresh-or-whole-foods)

### 4. Target

Target runs two separate, unconnected surfaces:

- **Redsky**, Target's internal product/price/fulfillment API platform, is
  partner-restricted — access is limited to vendors and integrators Target
  already has a relationship with, not open self-serve registration like
  Kroger's developer portal. Third-party trackers (RapidAPI, Parse.bot)
  document it, which suggests reverse-engineered rather than sanctioned
  third-party use.
- **Target Partners** (Impact-network affiliate program) gives trackable
  *product-page* links with commission, but no cart API — closer to a
  bookmark than Walmart's prefilled-cart link.

Net: possible today only via an unofficial/reverse-engineered API for
search plus an affiliate link for monetization — no clean, sanctioned path
for both search and cart the way Kroger and Walmart both offer.

Sources: [Target API — Products & Store Availability (Parse.bot)](https://parse.bot/marketplace/4596043a-f154-4cf4-b5cd-822ec6d860ae/target-com-api), [Target tech blog — aggregated APIs / Redsky](https://tech.target.com/blog/empowering-clients-api), [Target Partners](https://partners.target.com/)

### 5. Albertsons / Safeway / Vons / Jewel-Osco (Albertsons Media Collective)

Albertsons publishes APIs (Audiences, Campaigns, Performance) through its
retail media network, but these are ad-measurement tools for brands buying
media on Albertsons properties — not a shopper-facing product search or
cart API. No path today; worth re-checking if Albertsons ever opens a
shopper API the way Kroger has.

Source: [Albertsons opens retail media network data with API (Chain Store Age)](https://chainstoreage.com/albertsons-opens-retail-media-network-data-api-partnership)

### 6. Costco

No official API in any form. Product search would depend on third-party
scrapers (Apify, Unwrangle, Piloterr), which are fragile and likely against
Costco's terms of service. Costco does run a CPS affiliate program (via
Rakuten-adjacent networks) that could produce a Walmart-style trackable
link, but without an official product API there's no reliable way to know
what's in stock or its price before linking out.

Sources: [Costco affiliate program (affiliate-toolkit)](https://www.affiliate-toolkit.com/program/costco/), [Costco Search Results API (Unwrangle, third-party)](https://docs.unwrangle.com/costco-search-results-api/)

### 7. Mercato

Not a single retailer but an e-commerce platform for independent and
regional grocers (specialty stores, bakeries, butchers). It offers
enterprise-tier API access, which could be a way to reach small/local shops
this household might use — but it's a sales-engagement product, not a
self-serve developer signup, and it's unclear whether its API model fits a
personal shopping-list tool versus a retailer's own storefront.

Source: [Mercato — About Us](https://aboutus.mercato.com/)

### 8. Publix, H-E-B, Wegmans, Sprouts, ALDI — no direct path

None of these publish a public API for product search or cart access.
Today the only realistic way to reach them programmatically is indirectly,
through Instacart's platform (all five are Instacart-partnered retailers in
at least some regions). They aren't standalone candidates; they fall out of
candidate #1 for free if Instacart is integrated.

## Recommendation

If a third integration is worth building, **Instacart Developer Platform**
is the clear next step — it's the only option besides Kroger/Walmart with a
genuine first-party product-search-plus-cart API, and one integration
covers most of the other chains on this list instead of one-by-one work.
Everything else here is either ads/data-only (Albertsons), affiliate-link-only
with no reliable product data (Target, Costco), scoped to the wrong catalog
(Amazon Fresh/Whole Foods via general Amazon API), or has no public API at
all.
