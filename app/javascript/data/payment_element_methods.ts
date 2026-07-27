// Facts about individual Stripe Payment Element payment methods that both the checkout form
// (app/javascript/components/Checkout/payment.ts) and the tokenization code
// (app/javascript/data/card_payment_method_data.ts) need. It lives in its own module because
// those two import each other, so anything shared has to sit outside both of them to avoid a
// module cycle.

// Payment methods whose authorization Stripe rejects without `billing_details.name`. A digital
// (non-shipping) cart never otherwise needs a name, so checkout's Full name field is optional
// there — selecting one of these has to make it required, or the confirm fails with
// `parameter_missing` and the buyer sees an error they cannot act on. This is what made UPI
// unusable in July 2026 (gumroad-private#933) and Bancontact in the same way
// (gumroad-private#1306): Stripe's Bancontact docs state the customer's name is required for the
// authorization to succeed. UPI additionally needs a full street address, which is why it also
// switches the element into "element-full" collection mode (see
// paymentElementBillingDetailsCollection in card_payment_method_data.ts); Bancontact needs only
// the name, so it stays in "form" mode and checkout's own field supplies it.
const PAYMENT_ELEMENT_TYPES_REQUIRING_BILLING_NAME = ["upi", "bancontact"];

export const paymentElementRequiresBillingName = (type: string | null | undefined) =>
  type != null && PAYMENT_ELEMENT_TYPES_REQUIRING_BILLING_NAME.includes(type);
