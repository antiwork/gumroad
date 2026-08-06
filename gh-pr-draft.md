Fixes #6581

## What

Checkout state indicators — the focus ring, the selected payment method border, the checked radio mark — now render the seller's saved accent whenever buyers can perceive it. Accents that blend into the background still get rescued to a visible colour at 3:1, so a white accent on a white storefront keeps a usable focus ring.

## Why

The floor added in #6531 also recoloured accents that were plainly visible: the default pink on white shipped as a muted mauve on single-seller checkouts, while mixed carts kept the vivid pink. Review on #6588 found the muted version harder to recognize as focused. This applies that call consistently: vivid accents stay, and only invisible ones are adjusted. Ratios under WCAG 1.4.11's 3:1 for perceptible accents are accepted deliberately, and the code comment records that decision.

## Options considered

- **Keep every accent, rescue only invisible ones** — chosen. Smallest change, restores the brand pink for default themes, keeps the white-on-white safeguard, and makes both checkout paths match.
- **Two-layer ring** — keep the accent vivid and add a thin dark outer line that carries the 3:1 ratio. Solid fallback if we ever want strict compliance everywhere; heavier visual treatment and more styling plumbing, so deferred.
- **Leave it split** — muted ring for single-seller carts, vivid pink for mixed carts. Ruled out: the inconsistency was an accident of #6531 merging while #6588 was declined.

## Before/After

Single-seller cart, light mode. The indicator goes from muted `#d075bd` back to the saved accent (`#ff90e8` on default themes). Mixed carts and dark mode render the same before and after.

|  | Before | After |
| --- | --- | --- |
| **Desktop** | ![before desktop](https://raw.githubusercontent.com/antiwork/gumroad/gianfranco/floor-only-invisible-indicators/qa-media/pr-6614-indicator-before-desktop-light.png) | ![after desktop](https://raw.githubusercontent.com/antiwork/gumroad/gianfranco/floor-only-invisible-indicators/qa-media/pr-6614-indicator-after-desktop-light.png) |
| **Mobile** | ![before mobile](https://raw.githubusercontent.com/antiwork/gumroad/gianfranco/floor-only-invisible-indicators/qa-media/pr-6614-indicator-before-mobile-light.png) | ![after mobile](https://raw.githubusercontent.com/antiwork/gumroad/gianfranco/floor-only-invisible-indicators/qa-media/pr-6614-indicator-after-mobile-light.png) |

Safeguard unchanged — a seller with a white accent on a white background still gets a visible gray (`#949494`) ring and selection colour:

![safeguard white on white](https://raw.githubusercontent.com/antiwork/gumroad/gianfranco/floor-only-invisible-indicators/qa-media/pr-6614-indicator-safeguard-white-on-white.png)

QA: add one product to the cart, open checkout, click the card field and the tip options; repeat with products from two sellers to confirm the mixed-cart checkout is unaffected.

## Test Results

119 examples, 0 failures across `contrast_color_spec`, `seller_profile_spec`, and `checkout_controller_spec`. The new examples fail against the previous implementation.

![test results](https://raw.githubusercontent.com/antiwork/gumroad/gianfranco/floor-only-invisible-indicators/qa-media/pr-6614-indicator-test-results.png)

---

This PR was implemented with AI assistance using Claude Fable 5.
