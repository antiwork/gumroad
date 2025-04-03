## Running Apple Pay locally

Apple Pay is already enabled for these domains and sub-domains:

1. gumroad.dev
2. discover.gumroad.dev
3. creator.gumroad.dev

To see the apple pay button on custom domains, add the domain name to [Stripe Dashboard](https://dashboard.stripe.com/settings/payments/apple_pay) (or via Rails console: `Stripe::ApplePayDomain.create(domain_name: domain)`) and visit product checkout page from a [browser that supports Apple Pay](https://stripe.com/docs/stripe-js/elements/payment-request-button#html-js-testing).
