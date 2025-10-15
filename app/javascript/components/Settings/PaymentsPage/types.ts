import { StripeCardElement } from "@stripe/stripe-js";

export type RefundPaymentMethodCardData = { type: "saved" } | { type: "new"; element: StripeCardElement } | undefined;
