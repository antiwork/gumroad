## Running Apple Pay locally

Apple Pay cannot be tested against `http://localhost:3000` — Stripe requires HTTPS for Apple Pay domain registration, so the Apple Pay button will not render in local development. To test it, expose the app over HTTPS with [ngrok](https://ngrok.com/) (`ngrok http 3000`) and register the resulting hostname in the Stripe dashboard.

To see the apple pay button on custom domains, add the domain name to [Stripe Dashboard](https://dashboard.stripe.com/settings/payments/apple_pay) (or via Rails console: `Stripe::ApplePayDomain.create(domain_name: domain)`) and visit product checkout page from a [browser that supports Apple Pay](https://stripe.com/docs/stripe-js/elements/payment-request-button#html-js-testing).
