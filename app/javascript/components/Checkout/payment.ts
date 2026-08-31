import { enableMapSet, produce } from "immer";
import { groupBy } from "lodash-es";
import * as React from "react";

import { getSurcharges, SurchargesResponse } from "$app/data/customer_surcharge";
import { paymentElementRequiresBillingName } from "$app/data/payment_element_methods";
import { PurchasePaymentMethod } from "$app/data/purchase";
import { SavedCreditCard } from "$app/parsers/card";
import { CustomFieldDescriptor, ProductNativeType } from "$app/parsers/product";
import { assert } from "$app/utils/assert";
import { readBuyerCurrencyPreference, writeBuyerCurrencyPreference } from "$app/utils/buyerCurrencyPreference";
import { GST_ONLY_FALLBACK_PROVINCE, provinceForCanadianPostalCode } from "$app/utils/canadianPostalCodes";
import { isValidEmail } from "$app/utils/email";
import { calculateFirstInstallmentPaymentPriceCents } from "$app/utils/price";
import { asyncVoid } from "$app/utils/promise";
import { RecurrenceId } from "$app/utils/recurringPricing";
import { AbortError, assertResponseError } from "$app/utils/request";

import { loadAcknowledgedEmails } from "$app/components/Checkout/acknowledgedEmails";
import {
  getCheckoutBuyerCurrencyDisplay,
  isRecurringUpiPaymentConfig,
} from "$app/components/Checkout/buyerCurrencyDisplay";
import { Creator } from "$app/components/Checkout/cartState";
import { showAlert } from "$app/components/server-components/Alert";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRunOnce } from "$app/components/useRunOnce";

enableMapSet();

export type PaymentMethodType = "paypal" | "stripePaymentRequest" | "card";
export type PaymentMethod = { type: PaymentMethodType; button: React.ReactElement | null };

// Passed through to Stripe Elements as `mode`; these are Stripe's UI configuration values,
// not a selector for Gumroad's backend PaymentIntent/SetupIntent API path.
export const STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT = "payment";
export const STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT = "setup";

type StripeElementsModeForCheckout =
  | typeof STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT
  | typeof STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT;

const STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS = 50;

export type PaymentElementConfig = {
  stripe_elements_mode: StripeElementsModeForCheckout;
  currency: "usd";
  // True when the server chose the buyer-currency presentment lane (a cart of USD-priced
  // one-time items from a single seller in the buyer-currency rollout, for a buyer seeing
  // local-currency prices). The element then mounts in the currency of the FX quote from the surcharge
  // response — the same quote whose signed token prices the charge — so the payment sheet and
  // the charged amount always come from one source. Without a usable quote (expired, errored,
  // or the buyer opted to save the card, which forces the canonical USD charge path) the
  // element mounts canonical USD, exactly as if this flag were false.
  buyer_currency_presentment: boolean;
  payment_method_types: ["card"];
  payment_method_creation: "manual";
  stripe_link_enabled: boolean;
};
// Client-confirm mints a ConfirmationToken, so it omits payment_method_creation.
// payment_method_types is server-resolved and must match the deferred intent — the
// browser never widens it. Currency is usd except on direct-listed / method-forced
// surfaces, which mount in the listed currency so the Element, summary, and intent stay aligned.
export type ListedCurrencyDisplayConfig = {
  currency: string;
  // The backend's authoritative minor-unit scale for the currency, so formatting never relies on
  // the currencies.json single_unit heuristic.
  subunit_to_unit: number;
};
export type PaymentElementClientConfirmConfig = {
  stripe_elements_mode: typeof STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT;
  currency: string;
  presentment_amount_cents: number | null;
  listed_currency_display: ListedCurrencyDisplayConfig | null;
  // Marks the GeoIP/listed-price card lane. Unlike the method-forced lane, shipping moves
  // this Element back to canonical USD because charge-time eligibility excludes it.
  direct_listed_card?: boolean;
  // Raw page-issued FX rate signed into payment_method_list_token. Matches
  // CurrencyHelper#usd_cents_to_currency, not the display-scaled product.exchange_rate.
  direct_listed_currency_rate?: number | null;
  payment_method_types: string[];
  // Signed server copy of payment_method_types above, echoed back at /orders/prepare so the
  // deferred intent is built from the list this page actually mounted rather than a second
  // server-side resolution (gumroad-private#1528). Opaque to the browser.
  payment_method_list_token: string | null;
  stripe_link_enabled: boolean;
  stripe_connect_account_id: string | null;
};
// request_apple_pay_merchant_tokens: subscription carts ask Apple for an MPAN (survives a
// device wipe) instead of a device token. payment_element_wallets: PE renders wallets
// natively and the Payment Request Button is not mounted; always false on card_element.
// flat_payment_methods is independent of that flag (wallet-suppressed carts stay flat);
// always false on card_element, which has no accordion to act as the selector.
export type CheckoutPaymentConfig =
  | {
      integration: "card_element";
      fallback_reason: string;
      disable_wallets: boolean;
      request_apple_pay_merchant_tokens: boolean;
      india_card_mandate_reliability?: boolean;
      payment_element_wallets: boolean;
      flat_payment_methods: boolean;
      elements_options: null;
    }
  | {
      integration: "payment_element";
      fallback_reason: null;
      disable_wallets: boolean;
      request_apple_pay_merchant_tokens: boolean;
      india_card_mandate_reliability?: boolean;
      payment_element_wallets: boolean;
      flat_payment_methods: boolean;
      elements_options: PaymentElementConfig;
    }
  | {
      integration: "payment_element_client_confirm";
      fallback_reason: null;
      recurring_upi_registration: boolean;
      disable_wallets: boolean;
      request_apple_pay_merchant_tokens: boolean;
      india_card_mandate_reliability?: boolean;
      payment_element_wallets: boolean;
      flat_payment_methods: boolean;
      elements_options: PaymentElementClientConfirmConfig;
    };

export type Product = {
  permalink: string;
  uid?: string | undefined;
  name: string;
  creator: Creator;
  quantity: number;
  price: number;
  // The selected pre-discount subtotal in the product's listed currency. Recurring UPI uses it
  // to detect price or quantity edits that no longer match the server-rendered INR Element
  // amount while allowing a limited discount to change only today's charge.
  listedPriceCents?: number;
  // The post-discount amount the listed-currency charge will collect for this line today.
  listedChargePriceCents?: number;
  // What one renewal of a membership will charge, when it differs from `price` (e.g. a discount
  // limited to the first billing cycle, or a payment-method update on the subscription manage
  // page where `price` is today's charge — often zero — rather than the plan price). For
  // installment plans it overrides the per-installment amount otherwise derived from `price`.
  // Used to describe the recurring agreement on the Apple Pay sheet; null/absent means future
  // payments charge the same as today.
  renewalPriceCents?: number | null;
  payInInstallments: boolean;
  // Present when the buyer chose to pay in installments; describes the fixed monthly schedule so
  // the Apple Pay sheet can state it. `remainingInstallments` is set only on the subscription
  // manage page, where some installments have already been paid and `price` is today's charge
  // (not the plan total the future payments derive from at checkout).
  installmentPlan?: { numberOfInstallments: number; remainingInstallments?: number } | null;
  // For memberships that automatically end after a fixed period (product duration_in_months):
  // bounds the recurring agreement shown on the Apple Pay sheet instead of describing it as
  // billing until cancellation.
  durationInMonths?: number | null;
  requireShipping: boolean;
  customFields: CustomFieldDescriptor[];
  bundleProductCustomFields: { product: { id: string; name: string }; customFields: CustomFieldDescriptor[] }[];
  supportsPaypal: "native" | "braintree" | null;
  testPurchase: boolean;
  requirePayment: boolean;
  hasFreeTrial: boolean;
  hasTippingEnabled: boolean;
  isPreorder: boolean;
  canGift: boolean;
  nativeType: ProductNativeType;
  recurrence: RecurrenceId | null;
  subscription_id?: string;
  forceNewSubscription?: boolean;
  recommended_by?: string | null;
  shippableCountryCodes: string[];
};

export type Gift =
  | { type: "normal"; email: string; note: string }
  | { type: "anonymous"; id: string; name: string; note: string };

export type Tip =
  | { type: "percentage"; percentage: number }
  | {
      type: "fixed";
      // Canonical USD cents. Every USD-side consumer reads this — the surcharge quote's tax basis,
      // the large-tip threshold, the canonical totals — so it is always populated.
      amount: number | null;
      // The exact amount the buyer typed, in the listed currency's minor units, on the
      // method-forced listed-currency lane (a BRL product paid with Pix, an EUR product with
      // iDEAL, an INR product with UPI). That lane bills the listed amount directly, so the tip
      // the buyer chose has to survive to the charge unchanged; deriving it from `amount` cannot
      // do that, because converting a typed R$10.00 to canonical cents throws away roughly a
      // fifth of a centavo of precision at a 5.45 rate and no canonical figure converts back to
      // exactly R$10.00 (183 canonical cents bills R$9.96, 184 bills R$10.02).
      //
      // Null on every other checkout and whenever the buyer picked a percentage instead, in
      // which case the listed lane takes its percentage of the listed price — already exact.
      listedAmount?: number | null;
      // The exact amount the buyer typed in the currently displayed FX presentment currency.
      // Some amounts (CA$4.37 at a 1.25 quote) cannot round-trip through canonical USD cents,
      // so the input must keep the buyer's figure while the quote remints around it.
      presentmentAmount?: number | null;
      // The presentment currency that amount was typed in. A later currency pick must not
      // reinterpret CA$4.37 as £4.37 while the replacement quote is loading.
      presentmentCurrency?: string | null;
    };

// Whether a response's currency menu offers `code`. Undefined when the response carries no menu
// at all: a server from before the picker shipped says nothing about which currencies it can
// quote, and reading its silence as a refusal would reject every choice during a rolling deploy.
const offersBuyerCurrency = (surcharges: SurchargesResponse, code: string) =>
  surcharges.available_buyer_currencies?.some((option) => option.code === code);

const loadedBuyerCurrency = (state: Pick<State, "buyerCurrency" | "surcharges" | "tip">) => {
  if (state.buyerCurrency != null) return state.buyerCurrency;
  if (state.surcharges.type === "loaded" && state.surcharges.result.buyer_currency_quote?.currency)
    return state.surcharges.result.buyer_currency_quote.currency;
  if (state.tip.type === "fixed" && state.tip.presentmentAmount != null) return state.tip.presentmentCurrency ?? null;
  return null;
};

type CheckoutTaxLocation = { country: string; state: string; zipCode: string };
type PayPalBillingAddressTaxLocation = {
  country: string;
  zipCode: string | undefined;
  state?: string | null | undefined;
};

const paypalBillingStateForCheckout = (
  billingAddress: PayPalBillingAddressTaxLocation,
  checkout: CheckoutTaxLocation,
) =>
  billingAddress.state ||
  (billingAddress.country === "CA" ? provinceForCanadianPostalCode(billingAddress.zipCode) : null) ||
  (billingAddress.country === checkout.country ? checkout.state : null) ||
  (billingAddress.country === "CA" ? GST_ONLY_FALLBACK_PROVINCE : null) ||
  "";

export const paypalBillingAddressForCheckout = (
  billingAddress: PayPalBillingAddressTaxLocation,
  checkout: CheckoutTaxLocation,
) => ({
  country: billingAddress.country,
  zipCode: billingAddress.zipCode || (billingAddress.country === checkout.country ? checkout.zipCode : ""),
  state: paypalBillingStateForCheckout(billingAddress, checkout),
});

export const paypalBillingAddressChangesTaxLocation = (
  billingAddress: PayPalBillingAddressTaxLocation,
  checkout: CheckoutTaxLocation,
) => {
  const next = paypalBillingAddressForCheckout(billingAddress, checkout);
  return (
    next.country !== checkout.country ||
    (next.country === "US" && next.zipCode !== checkout.zipCode) ||
    (next.country === "CA" && next.state !== checkout.state)
  );
};

export { readBuyerCurrencyPreference, writeBuyerCurrencyPreference };

export type State = {
  products: Product[];
  buyerCurrency: string | null;
  // The quote that was on screen when the buyer changed currency (or switched payment surface),
  // held only until the replacement lands. Both leave the cart alone, and a currency change is the
  // one whose control lives inside the summary it blanks, so the summary renders from this
  // snapshot to keep its rows — and the picker the buyer is still holding focus in — in place
  // across the round trip. `previousCurrency` is what the selection goes back to if the chosen
  // currency turns out to be unquotable.
  buyerCurrencyRemint: {
    surcharges: SurchargesResponse;
    previousCurrency: string | null;
    // Set when the refetch was a payment-surface switch (saved card ⇄ Payment Element) rather
    // than the buyer picking a currency. Those switches change which currencies the server
    // advertises but leave the selection alone, so there is nothing to put back and no refusal
    // to report — the snapshot is held only so the summary keeps its amounts across the trip.
    surfaceSwitch?: boolean;
    // The surface the buyer was on when a surface-switch snapshot was taken. Which currency the
    // summary is in is a function of that surface — a saved card charges canonical USD, a new
    // card can charge the listed currency — so rendering the held amounts under the NEW surface
    // flips them between listed and USD the instant the toggle moves, which is the mid-flight
    // total change the snapshot exists to prevent. Display only; pay and disable gates keep
    // reading live `usingSavedCard`.
    previousUsingSavedCard?: boolean;
  } | null;
  // A currency the buyer chose that the server then came back without. The summary names it, so a
  // total that reverts to another currency says why instead of changing under the buyer.
  unavailableBuyerCurrency: string | null;
  countries: Record<string, string>;
  usStates: string[];
  caProvinces: string[];
  tipOptions: number[];
  country: string;
  email: string;
  vatId: string;
  fullName: string;
  address: string;
  city: string;
  state: string;
  zipCode: string;
  saveAddress: boolean;
  gift: Gift | null;
  customFieldValues: Record<string, string>;
  surcharges:
    | { type: "error" | "pending" }
    // requestId identifies which fetch this loading state belongs to. A response may only
    // publish its result through the reducer when the state is still "loading" with the same
    // requestId — see the "surcharges-fetch-succeeded"/"surcharges-fetch-failed" cases. That
    // makes the stale-response fence part of the reducer's dispatch ordering instead of a
    // mutable ref read, which could race the response between an invalidating dispatch and
    // the passive effect that reacted to it.
    | { type: "loading"; requestId: number; abort: () => void }
    | { type: "loaded"; result: SurchargesResponse };
  availablePaymentMethods: PaymentMethod[];
  paymentMethod: PaymentMethodType;
  // Which payment-method row the buyer has selected INSIDE the Stripe Payment Element ("card",
  // "upi", "apple_pay", ...), mirrored from the element's change event. Checkout's own form
  // reacts to it: for selections where the element collects the full billing details itself
  // (UPI on digital carts — see paymentElementBillingDetailsCollection in
  // card_payment_method_data.ts), the form hides its Full name and Country/ZIP fields so the
  // buyer is never asked for the same information twice. Always "card" when the element is not
  // mounted (that is the element's own default selection).
  paymentElementType: string;
  // Card checkouts that save the card charge canonically in PR 1 (no buyer-presentment), so
  // buyer-currency display and the quote token are suppressed while this is set.
  willSaveCard: boolean;
  // True while the buyer is paying with a card already on file. Saved cards stay on the
  // server-confirm path, which never mints a ConfirmationToken and so never reaches client-confirm
  // presentment — the charge is canonical USD. Mirrored into state (rather than
  // staying local to PaymentForm) because the cart summary has to know: it is the default selection
  // for any returning buyer, and showing listed-currency totals for a canonical-USD charge is the
  // display/charge mismatch we are fixing (gumroad-private#1371).
  usingSavedCard: boolean;
  savedCreditCard: SavedCreditCard | null;
  checkoutPayment: CheckoutPaymentConfig;
  // True while the cart has been edited but the server has not yet returned the payment
  // configuration for the edited cart. The configuration decides which element is mounted and in
  // which currency, and a cart edit can change the answer, so paying during this window would
  // pay through an element built for the previous cart. isSubmitDisabled blocks Pay until the
  // refreshed configuration lands (the same treatment an in-flight surcharge refresh gets).
  checkoutPaymentStale: boolean;
  // True when a submit was refused only because the payment configuration was stale, and so has to
  // be re-tried once the refreshed configuration lands. Without this the offer pipeline deadlocks:
  // accepting an offer invalidates the configuration and then dispatches "validate" in the same
  // tick, that "validate" is refused back to "input", and nothing ever re-submits — the buyer is
  // left on the checkout page with no feedback after the purchase they already confirmed.
  resumeSubmitAfterCheckoutPayment: boolean;
  // Counts submits refused by client-side validation. A refused submit usually goes "input" →
  // "input" (Pay is clicked from "input" and the failure sets "input" again), so effects keyed
  // on the status type alone never see it — PaymentForm keys its scroll-to-first-error effect
  // on this counter instead (gumroad-private#1703).
  validationFailedCount: number;
  status:
    | { type: "input"; errors: Set<string> }
    | { type: "offering" }
    | { type: "validating" }
    | { type: "starting" }
    // `challengeFallback` marks the second pass through the CAPTCHA step after the server refused
    // the order on risk score alone: the token comes from the challenge key rather than the score
    // key, and the order request says so (see "retry-recaptcha-challenge").
    | { type: "captcha"; paymentMethod: PurchasePaymentMethod; challengeFallback?: boolean }
    | {
        type: "finished";
        recaptchaResponse?: string;
        paymentMethod: PurchasePaymentMethod;
        challengeFallback?: boolean;
      };
  payLabel?: string;
  recaptchaKey: string | null;
  recaptchaScoreBased: boolean;
  recaptchaChallengeKey: string | null;
  paypalClientId?: string;
  tip: Tip;
  warning?: string | null;
  emailTypoSuggestion: string | null;
  acknowledgedEmails: Set<string>;
  requireEmailTypoAcknowledgment: boolean;
};

type StateWithPaymentElementCheckout = State & {
  checkoutPayment: Extract<CheckoutPaymentConfig, { integration: "payment_element" }>;
};

type StateWithPaymentElementClientConfirmCheckout = State & {
  checkoutPayment: Extract<CheckoutPaymentConfig, { integration: "payment_element_client_confirm" }>;
};

export const addressFields = ["address", "city", "state", "zipCode", "fullName", "country"] as const;

type SimpleValue =
  | "country"
  | "email"
  | "vatId"
  | "fullName"
  | "address"
  | "city"
  | "state"
  | "zipCode"
  | "saveAddress"
  | "paymentMethod"
  | "paymentElementType"
  | "willSaveCard"
  | "usingSavedCard"
  | "gift"
  | "payLabel"
  | "warning"
  | "tip"
  | "emailTypoSuggestion"
  | "buyerCurrency";

type PublicAction =
  | ({ type: "set-value" } & Partial<{ [key in SimpleValue]?: State[key] | undefined }>)
  // A wallet sheet's billing address adopted as checkout's tax location mid-payment (see the
  // reducer case for why this is not a plain "set-value").
  | { type: "set-wallet-billing-address"; country: string; zipCode: string | undefined; state: string }
  // PayPal returns the account tax location after the buyer approves the agreement. If that
  // changes the taxable location, the buyer has to review the updated total before any capture.
  | {
      type: "set-paypal-billing-address";
      country: string;
      zipCode: string | undefined;
      state?: string | null | undefined;
      fullName: string;
      email?: string;
    }
  | { type: "set-custom-field"; key: string; value: string }
  | { type: "add-payment-method"; paymentMethod: PaymentMethod }
  | { type: "offer" }
  | { type: "validate" }
  | { type: "start-payment" }
  | { type: "set-recaptcha-response"; recaptchaResponse?: string }
  // The order was refused because the score key scored the session as risky. Send the buyer back
  // through the CAPTCHA step against the challenge key, which can ask them to prove humanity
  // instead of only scoring them (gumroad-private#1590).
  | { type: "retry-recaptcha-challenge" }
  | { type: "set-payment-method"; paymentMethod: PurchasePaymentMethod }
  | { type: "acknowledge-email-typo"; email: string }
  | {
      type: "update-products";
      products: Product[];
      surcharges?: SurchargesResponse;
    }
  // The cart was edited in a way that can change which payment lane it belongs to (its set of
  // sellers, its recurrence, its installment choice), so the server has to recompute the payment
  // configuration for the new cart. Marks the configuration on screen as stale; the refreshed
  // one arrives as "update-checkout-payment" below.
  | { type: "invalidate-checkout-payment" }
  // The recomputed payment configuration for the edited cart, from a partial reload of the
  // checkout page's props.
  | { type: "update-checkout-payment"; checkoutPayment: CheckoutPaymentConfig }
  | { type: "cancel" };

type Action =
  | PublicAction
  | ({ type: "set-value" } & Partial<State>)
  // Internal actions dispatched by the surcharge refetch machinery in createReducer. They
  // carry the requestId of the fetch that produced them so the reducer can drop responses
  // from a request that is no longer the current one (see the reducer cases).
  | { type: "surcharges-fetch-succeeded"; requestId: number; result: SurchargesResponse }
  | { type: "surcharges-fetch-failed"; requestId: number };

export function usePayLabel() {
  const [state] = useState();
  return isProcessing(state) ? "Processing..." : (state.payLabel ?? (requiresPayment(state) ? "Pay" : "Get"));
}

export function requiresPayment(state: State) {
  return getTotalPrice(state) !== 0 || state.products.some((item) => item.requirePayment);
}

function hasMultipleSellers(state: State) {
  return new Set(state.products.map((product) => product.creator.id)).size > 1;
}

export function requiresReusablePaymentMethod(state: State) {
  return (
    hasMultipleSellers(state) || !!state.products[0]?.subscription_id || state.products[0]?.nativeType === "commission"
  );
}

export function requiresPaymentElementReusablePaymentMethod(state: State) {
  return (
    requiresReusablePaymentMethod(state) ||
    state.products.some(
      (product) =>
        !!product.recurrence ||
        !!product.subscription_id ||
        product.nativeType === "commission" ||
        product.payInInstallments,
    )
  );
}

export function requiresReusablePaymentMethodForCardCollection(state: State, useStripePaymentElement: boolean) {
  if (!useStripePaymentElement) {
    return state.checkoutPayment.india_card_mandate_reliability
      ? requiresPaymentElementReusablePaymentMethod(state)
      : requiresReusablePaymentMethod(state);
  }
  if (
    state.checkoutPayment.integration === "payment_element" &&
    state.checkoutPayment.elements_options.stripe_elements_mode === STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT
  )
    return false;
  return requiresPaymentElementReusablePaymentMethod(state);
}

export function canUseStripePaymentElement(state: State): state is StateWithPaymentElementCheckout {
  if (state.products.length === 0) return false;
  if (state.checkoutPayment.integration !== "payment_element") return false;

  if (state.checkoutPayment.elements_options.stripe_elements_mode === STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT) {
    return canUseStripePaymentElementForFutureChargeSetup(state);
  }

  // A surcharge reload can lower the amount charged now after Rails chooses the lane. Apply
  // Stripe's floor to the same server-owned amount the Element mounts with.
  if (state.surcharges.type === "loaded") {
    const chargeToday = getChargeTodayPrice(state);
    if (chargeToday === null || chargeToday < STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS) return false;
  }

  // Free trials and preorders charge nothing today, so payment mode is never right for them.
  return !state.products.some((product) => product.hasFreeTrial || product.isPreorder);
}

function isRecurringUpiRegistrationCheckout(
  state: State,
  config: StateWithPaymentElementClientConfirmCheckout["checkoutPayment"],
) {
  const [product] = state.products;
  const options = config.elements_options;

  return (
    isRecurringUpiPaymentConfig(config) &&
    state.products.length === 1 &&
    product?.quantity === 1 &&
    !!product.recurrence &&
    product.listedPriceCents === options.presentment_amount_cents &&
    product.installmentPlan == null &&
    !product.requireShipping &&
    state.gift === null
  );
}

// The browser must not widen server eligibility. Recurring client-confirm is limited to the
// server-selected UPI registration lane while the live cart retains that lane's shape.
export function canUseStripePaymentElementClientConfirm(
  state: State,
): state is StateWithPaymentElementClientConfirmCheckout {
  if (state.products.length === 0) return false;
  if (state.checkoutPayment.integration !== "payment_element_client_confirm") return false;
  if (hasMultipleSellers(state)) return false;

  if (state.surcharges.type === "loaded") {
    const total = getTotalPrice(state);
    if (total === null || total < STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS) return false;
  }

  const recurringUpiRegistration = isRecurringUpiRegistrationCheckout(state, state.checkoutPayment);
  if (state.checkoutPayment.recurring_upi_registration && !recurringUpiRegistration) return false;

  return !state.products.some(
    (product) =>
      product.payInInstallments ||
      product.hasFreeTrial ||
      product.isPreorder ||
      (!!product.recurrence && !recurringUpiRegistration) ||
      !!product.subscription_id ||
      product.nativeType === "commission",
  );
}

function canUseStripePaymentElementForFutureChargeSetup(state: State) {
  return (
    !hasMultipleSellers(state) &&
    !state.products.some((product) => product.payInInstallments) &&
    state.products.every((product) => product.isPreorder || product.hasFreeTrial) &&
    getTotalPriceFromProducts(state) > 0
  );
}

export function getStripePaymentElementAmount(state: State) {
  if (state.surcharges.type !== "loaded") return null;
  if (!canUseStripePaymentElement(state) && !canUseStripePaymentElementClientConfirm(state)) return null;
  if (
    state.checkoutPayment.integration === "payment_element" &&
    state.checkoutPayment.elements_options.stripe_elements_mode === STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT
  )
    return null;
  // A client-confirm surface can become quote-backed after a total-affecting edit. Prefer the
  // loaded quote before the server-rendered listed amount from the stale initial configuration.
  const presentment = getStripePaymentElementPresentment(state);
  if (presentment) return presentment.amountCents;
  // Recurring UPI is a server-selected INR registration lane. A stale stored USD picker
  // preference must not reinterpret either the Element amount or its currency.
  if (
    state.checkoutPayment.integration === "payment_element_client_confirm" &&
    isRecurringUpiPaymentConfig(state.checkoutPayment)
  )
    return state.checkoutPayment.elements_options.presentment_amount_cents;
  // Direct-listed surfaces mount in the listed currency, so the USD total below would be the
  // wrong unit. Add any listed-currency tip the buyer selected to the server-rendered base amount
  // so Elements and the deferred intent stay aligned after surcharge-only tip edits.
  if (
    state.checkoutPayment.integration === "payment_element_client_confirm" &&
    state.checkoutPayment.elements_options.presentment_amount_cents !== null &&
    ((!state.checkoutPayment.elements_options.direct_listed_card && state.buyerCurrency?.toLowerCase() !== "usd") ||
      (getSelectableDirectListedCurrency(state) !== null && state.buyerCurrency?.toLowerCase() !== "usd"))
  )
    return getDirectListedPaymentElementAmount(state);
  // Partial-payment carts mount with the amount the server will charge now, not the agreement total.
  return getChargeTodayPrice(state);
}

// The mount currency + amount for the buyer-currency presentment lane, or null everywhere else.
// Non-null when the server chose the lane, or when a stale client-confirm configuration receives
// a usable quote after a total-affecting edit.
// Both the element mount and the charge derive from that one quote — the element shows the
// buyer the exact local-currency amount whose signed token the server verifies at charge time.
// When the quote is missing or suppressed (expired/errored quote, or the buyer chose to save
// the card, which PR 1 forces onto the canonical USD charge path), this returns null and the
// element mounts canonical USD — matching the canonical charge the fallback performs.
export function getStripePaymentElementPresentment(state: State): { currency: string; amountCents: number } | null {
  const presentmentEnabled =
    (state.checkoutPayment.integration === "payment_element" &&
      state.checkoutPayment.elements_options.buyer_currency_presentment) ||
    clientConfirmBuyerCurrencyPresentmentEnabled(state);
  if (!presentmentEnabled) return null;
  if (state.surcharges.type !== "loaded") return null;

  // Deliberately independent of state.paymentElementType: a wallet selection must keep the
  // presentment, or the mount currency flips and the remount wipes the selection.
  const display = getCheckoutBuyerCurrencyDisplay(state.surcharges.result, {
    cartPermalinks: state.products.map((product) => product.permalink),
    willSaveCard: state.willSaveCard,
    paymentMethod: state.paymentMethod,
  });
  if (!display) return null;

  return { currency: display.currencyCode, amountCents: display.chargePresentmentTotalCents };
}

export function shouldSuppressClientConfirmWallets(state: State) {
  if (!clientConfirmBuyerCurrencyPresentmentEnabled(state) || state.willSaveCard) return false;
  if (state.buyerCurrency !== null && state.buyerCurrency.toLowerCase() !== "usd") return true;
  if (state.surcharges.type !== "loaded") return false;

  // Read the display as a plain card selection: the current wallet surface must not stay
  // alive after a valid quote arrives.
  return (
    getCheckoutBuyerCurrencyDisplay(state.surcharges.result, {
      cartPermalinks: state.products.map((product) => product.permalink),
      paymentMethod: "card",
    }) !== null
  );
}

// The currency the Payment Element should mount in. Direct-listed client-confirm checkouts use
// the server-selected listed currency only while their cart stays eligible. The server-confirm
// FX lane derives its currency from the surcharge quote; returning null while that quote reloads
// preserves the current Element instead of remounting and wiping entered card details.
export function getStripePaymentElementMountCurrency(state: State): string | null {
  if (state.checkoutPayment.integration === "payment_element_client_confirm") {
    if (
      (getConfiguredDirectListedCurrency(state) !== null || clientConfirmBuyerCurrencyPresentmentEnabled(state)) &&
      state.surcharges.type !== "loaded"
    )
      return null;
    return getStripePaymentElementPresentment(state)?.currency ?? getDesiredStripePaymentElementMountCurrency(state);
  }
  if (state.checkoutPayment.integration !== "payment_element") return null;
  const elementsOptions = state.checkoutPayment.elements_options;
  if (!elementsOptions.buyer_currency_presentment) return elementsOptions.currency;
  if (state.surcharges.type !== "loaded") return null;
  return getStripePaymentElementPresentment(state)?.currency ?? elementsOptions.currency;
}

function clientConfirmBuyerCurrencyPresentmentEnabled(state: State) {
  return (
    state.checkoutPayment.integration === "payment_element_client_confirm" &&
    !state.checkoutPayment.recurring_upi_registration &&
    getConfiguredDirectListedCurrency(state) === null
  );
}

export function getConfiguredDirectListedCurrency(state: Pick<State, "checkoutPayment">): string | null {
  if (state.checkoutPayment.integration !== "payment_element_client_confirm") return null;

  const options = state.checkoutPayment.elements_options;
  const currency = options.currency.toLowerCase();
  if (!options.direct_listed_card || options.presentment_amount_cents === null || options.presentment_amount_cents <= 0)
    return null;
  if (options.listed_currency_display?.currency.toLowerCase() !== currency) return null;

  return currency;
}

// `usingSavedCard` defaults to the live surface. The summary passes the surface a surface-switch
// remint was taken on instead, so its held amounts stay in the currency they were quoted in until
// the replacement lands — see getDisplayedUsingSavedCard.
export function getSelectableDirectListedCurrency(
  state: State,
  { usingSavedCard = state.usingSavedCard }: { usingSavedCard?: boolean } = {},
): string | null {
  const currency = getConfiguredDirectListedCurrency(state);
  if (!currency || !directListedCardActive(state, usingSavedCard) || !canUseStripePaymentElementClientConfirm(state))
    return null;

  return currency;
}

// The payment surface the summary renders as of: the pre-toggle one while a surface-switch remint
// is still on screen, the live one otherwise.
export function getDisplayedUsingSavedCard(state: Pick<State, "usingSavedCard" | "buyerCurrencyRemint">): boolean {
  const remint = state.buyerCurrencyRemint;
  return remint?.surfaceSwitch ? (remint.previousUsingSavedCard ?? state.usingSavedCard) : state.usingSavedCard;
}

function getDesiredStripePaymentElementMountCurrency(state: State): string | null {
  if (state.checkoutPayment.integration !== "payment_element_client_confirm") return null;
  if (isRecurringUpiPaymentConfig(state.checkoutPayment)) return state.checkoutPayment.elements_options.currency;

  const configuredDirectListedCurrency = getConfiguredDirectListedCurrency(state);
  if (!configuredDirectListedCurrency) {
    if (state.buyerCurrency?.toLowerCase() === "usd") return "usd";
    return state.checkoutPayment.elements_options.direct_listed_card
      ? "usd"
      : state.checkoutPayment.elements_options.currency;
  }

  return getSelectableDirectListedCurrency(state) !== null && state.buyerCurrency?.toLowerCase() !== "usd"
    ? configuredDirectListedCurrency
    : "usd";
}

function directListedCardActive(state: State, usingSavedCard = state.usingSavedCard) {
  return state.paymentMethod === "card" && !usingSavedCard && !hasShipping(state);
}

function getDirectListedPaymentElementAmount(state: State) {
  if (state.checkoutPayment.integration !== "payment_element_client_confirm") return getChargeTodayPrice(state);
  if (state.surcharges.type !== "loaded") return null;

  const directListedAllocations = state.surcharges.result.direct_listed_line_allocations;
  if (directListedAllocations?.length === state.products.length) {
    const allocationsMatchCart = directListedAllocations.every(
      (allocation, index) => allocation.permalink === state.products[index]?.permalink,
    );
    if (allocationsMatchCart)
      return directListedAllocations.reduce((sum, allocation) => sum + allocation.total_cents, 0);
  }

  const taxUsd = state.surcharges.result.tax_cents;
  const shippingUsd = state.surcharges.result.shipping_rate_cents;
  // Charge time converts each purchase separately. An aggregate USD→listed
  // fallback can disagree by a cent on multi-line carts, so do not mount.
  if (taxUsd !== 0 || shippingUsd !== 0) return null;

  const baseAmount = state.checkoutPayment.elements_options.presentment_amount_cents ?? 0;
  const linePrices = state.products.map((product) => ({
    price:
      product.listedChargePriceCents ??
      product.listedPriceCents ??
      (state.products.length === 1 ? baseAmount : product.price),
    permalink: product.permalink,
  }));
  const lineTotal = linePrices.reduce<number>((sum, line) => sum + line.price, 0);
  const tipTotal = computeTipsForLines(state, linePrices, { basis: "listed" }).reduce<number>(
    (sum, tip) => sum + (tip ?? 0),
    0,
  );

  return lineTotal + tipTotal;
}

export function isProcessing(state: State) {
  return state.status.type !== "input";
}

export function isSubmitDisabled(state: State) {
  const emailTypoBlocking = state.requireEmailTypoAcknowledgment && state.emailTypoSuggestion !== null;
  // checkoutPaymentStale: a cart edit is still waiting on the server's answer for which element
  // this cart should be paying through. Same reasoning as an unloaded surcharge response — the
  // buyer must not be able to pay on a configuration computed for the previous cart.
  return isProcessing(state) || state.surcharges.type !== "loaded" || state.checkoutPaymentStale || emailTypoBlocking;
}

export function isCardReadyToPay({
  useSavedCard,
  useStripePaymentElement,
  paymentElementReady,
}: {
  useSavedCard: boolean;
  useStripePaymentElement: boolean;
  paymentElementReady: boolean;
}) {
  if (useSavedCard || !useStripePaymentElement) return true;
  return paymentElementReady;
}

export const getTotalPriceFromProducts = (state: State) => state.products.reduce((sum, item) => sum + item.price, 0);

export function isTippingEnabled(state: State) {
  return (
    state.products.every((product) => product.hasTippingEnabled) &&
    !state.products.every((product) => product.nativeType === "coffee") &&
    getTotalPriceFromProducts(state) > 0
  );
}

const LARGE_TIP_THRESHOLD_CENTS = 10000;

export function isTipSuspiciouslyLarge(state: State): boolean {
  const tipCents = computeTip(state);
  if (tipCents === 0) return false;
  const productTotal = getTotalPriceFromProducts(state);
  return tipCents > LARGE_TIP_THRESHOLD_CENTS && tipCents > productTotal;
}

export function computeTip(state: State) {
  if (!isTippingEnabled(state)) return 0;
  if (state.tip.type === "fixed") {
    return state.tip.amount ?? 0;
  }
  return Math.round((state.tip.percentage / 100) * getTotalPriceFromProducts(state));
}

export function computeTipForPrice(state: State, price: number, permalink: string | undefined = undefined) {
  if (!isTippingEnabled(state)) return null;
  if (state.tip.type === "fixed") {
    const totalPrice = getTotalPriceFromProducts(state);
    if (totalPrice === 0) {
      return computeTipForFreeCart(state, permalink);
    }

    return Math.round((state.tip.amount ?? 0) * (price / totalPrice));
  }

  return Math.round((state.tip.percentage / 100) * price);
}

// Per-line tips that sum exactly to the cart tip. computeTipForPrice rounds each line
// independently and overshoots (1¢ fixed on two items → 2¢; [999,1999,2999] @ 20% → 1200
// vs computeTip 1199). Largest-remainder. Surcharge quotes and order lines must share this
// function: the quote token is verified against purchase line totals.
export function computeTipsForLines(
  state: State,
  lines: { price: number; permalink: string | undefined }[],
  // Which currency the caller's line prices — and therefore the tips it wants back — are in.
  // "canonical" (the default) is USD, as `state.products` holds. "listed" means the caller is on
  // the method-forced lane and passed the products' own minor units, in which case a fixed tip is
  // allocated from the amount the buyer literally typed rather than from its canonical rounding,
  // so the tip charged is the tip chosen. See the `listedAmount` note on `Tip`.
  { basis = "canonical" }: { basis?: "canonical" | "listed" } = {},
): (number | null)[] {
  if (!isTippingEnabled(state)) return lines.map(() => null);
  if (state.tip.type === "fixed") {
    const listedAmount = basis === "listed" ? state.tip.listedAmount : null;
    const totalPriceCents =
      listedAmount != null ? lines.reduce((sum, line) => sum + line.price, 0) : getTotalPriceFromProducts(state);
    if (totalPriceCents === 0) {
      return lines.map((line) => computeTipForFreeCart(state, line.permalink));
    }
    return allocateFixedTipCents(listedAmount ?? state.tip.amount ?? 0, lines, totalPriceCents);
  }
  // One cart tip, then the same allocator fixed tips use. The tip must be derived from the
  // caller's own line bases, never from `state.products`: on the canonical lane the caller's
  // prices are the products' own minor units while `state.products` holds unrounded USD, so
  // mixing them misprices every non-USD cart's tip. Deriving from the lines is unit-correct on
  // both lanes, and commission-deposit lines tip on the deposit they charge today, as before.
  const totalPriceCents = lines.reduce((sum, line) => sum + line.price, 0);
  const tipCents = Math.round((state.tip.percentage / 100) * totalPriceCents);
  return allocateFixedTipCents(tipCents, lines, totalPriceCents);
}

// Listed-lane display tip, in the listed currency's minor units. Do not convert the
// canonical computeTip figure: a percentage double-rounds one unit low, and a fixed tip
// converted at the FX rate disagrees with allocateFixedTipCents. Callers pass the same
// getDiscountedPrice(...) bases the order will submit so display and charge match.
export function computeTipForListedLines(state: State, lines: { price: number; permalink: string | undefined }[]) {
  return computeTipsForLines(state, lines, { basis: "listed" }).reduce<number>((sum, tip) => sum + (tip ?? 0), 0);
}

function allocateFixedTipCents(tipAmountCents: number, lines: { price: number }[], totalPriceCents: number): number[] {
  // Used for both fixed tip amounts and the single cart tip derived from a percentage, so
  // per-line integers always sum to the tip the buyer saw (or the listed-lane equivalent).
  if (tipAmountCents <= 0 || totalPriceCents <= 0) return lines.map(() => 0);

  const exactShares = lines.map((line) => (tipAmountCents * line.price) / totalPriceCents);
  const allocations = exactShares.map((share) => Math.floor(share));
  let remainderCents = tipAmountCents - allocations.reduce((sum, cents) => sum + cents, 0);
  // Hand the leftover cents to the lines that were floored the furthest below their exact
  // share, breaking ties by cart position so the allocation is deterministic. Each line
  // receives at most one extra cent (i.e. never more than the ceiling of its exact share):
  // when a line's price basis is smaller than its entry in the cart total (a commission
  // charging only its deposit today, a free-trial line about to be zeroed by the caller),
  // the shares intentionally sum to less than the full tip, and the leftover must stay
  // uncollected rather than being piled onto other lines beyond what the buyer's
  // proportional split says they owe.
  const linesByFractionDesc = exactShares
    .map((share, index) => ({ fraction: share - Math.floor(share), index }))
    .filter(({ fraction }) => fraction > 0)
    .sort((a, b) => b.fraction - a.fraction || a.index - b.index);
  for (const { index } of linesByFractionDesc) {
    if (remainderCents <= 0) break;
    allocations[index] = (allocations[index] ?? 0) + 1;
    remainderCents -= 1;
  }
  return allocations;
}

function computeTipForFreeCart(state: State, permalink?: string): number {
  if (state.tip.type !== "fixed" || !state.tip.amount) return 0;
  // TODO (techdebt): Replace lodash `groupBy` with https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Object/groupBy
  // when project upgrades to https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-7.html#support-for---target-es2024-and---lib-es2024
  const creatorGroups = groupBy(state.products, (product) => product.creator.id);
  if (Object.values(creatorGroups).some((products) => products[0]?.permalink === permalink)) {
    return Math.round(state.tip.amount / Object.keys(creatorGroups).length);
  }
  return 0;
}

export const getTotalPriceFromSurcharges = (surcharges: SurchargesResponse | null) =>
  surcharges ? surcharges.subtotal + surcharges.tax_cents + surcharges.shipping_rate_cents : null;

export function getTotalPrice(state: State) {
  return getTotalPriceFromSurcharges(state.surcharges.type === "loaded" ? state.surcharges.result : null);
}

// The pre-tax sum of all future installment payments. Besides the summary row, this is the
// rolling-deploy fallback for the charge-now mount amount and its Stripe floor check. Tips are
// charged upfront; taxes remain in the checkout table's "Payment today" display.
//
// Items with remainingInstallments set (subscription manage page) are skipped: there `price` is
// today's charge alone — future installments were never part of it, so nothing needs deducting.
export function getFutureInstallmentsTotal(state: State) {
  return state.products.reduce((sum, item) => {
    if (!item.payInInstallments || item.installmentPlan == null) return sum;
    if (item.installmentPlan.remainingInstallments != null) return sum;
    return (
      sum +
      (item.price - calculateFirstInstallmentPaymentPriceCents(item.price, item.installmentPlan.numberOfInstallments))
    );
  }, 0);
}

// What the server will charge now, including only the tax on today's installment. The fallback
// keeps a response from an older server usable during a rolling deploy.
export function getChargeTodayPrice(state: State) {
  const total = getTotalPrice(state);
  if (total === null) return null;
  const serverChargeTotal =
    state.surcharges.type === "loaded" ? state.surcharges.result.charge_canonical_total_cents : null;
  if (serverChargeTotal != null) return serverChargeTotal;
  return total - getFutureInstallmentsTotal(state);
}

export function getCustomFieldKey(
  field: CustomFieldDescriptor,
  product: { permalink: string; bundleProductId?: string | null },
) {
  return field.collect_per_product ? `${product.permalink}-${product.bundleProductId ?? ""}-${field.id}` : field.id;
}

export const hasShipping = (state: State) => state.products.some((item) => item.requireShipping);

// UPI on digital carts: the Payment Element collects full billing details. Duplicated from
// paymentElementBillingDetailsCollection to avoid a cycle with card_payment_method_data.ts.
// Hide Country/ZIP (the element collects them) but keep Full name — the pane's name field
// is "never". False again if the buyer leaves the card/element lane (e.g. PayPal).
export const paymentElementCollectsFullBillingDetails = (state: State) =>
  state.paymentMethod === "card" &&
  state.paymentElementType === "upi" &&
  !hasShipping(state) &&
  (canUseStripePaymentElement(state) || canUseStripePaymentElementClientConfirm(state));

// Bancontact needs billing_details.name but stays in "form" collection mode, so the
// full-details helper above is false and a digital cart would otherwise skip the name
// field (gumroad-private#1306). Method list lives in $app/data/payment_element_methods
// to stay cycle-free. Drop the requirement if the buyer leaves the card/element lane.
export const paymentElementRequiresBillingNameForSelection = (state: State) =>
  state.paymentMethod === "card" &&
  paymentElementRequiresBillingName(state.paymentElementType) &&
  (canUseStripePaymentElement(state) || canUseStripePaymentElementClientConfirm(state));

export const getErrors = (state: State) => (state.status.type === "input" ? state.status.errors : new Set());

export const loadSurcharges = (state: State, abortSignal?: AbortSignal) => {
  const isGift = state.gift !== null;
  const paymentDetailsSource = state.usingSavedCard
    ? "saved_payment_method"
    : state.paymentMethod === "card" && canUseStripePaymentElementClientConfirm(state)
      ? "payment_element"
      : undefined;
  const paymentElementMountCurrency =
    paymentDetailsSource === "payment_element" ? getDesiredStripePaymentElementMountCurrency(state) : null;
  const paymentElementDirectListedCurrency =
    paymentDetailsSource === "payment_element" ? getSelectableDirectListedCurrency(state) : null;
  // Allocate the tip across cart lines in one pass so the per-line integers sum to the
  // tip the buyer selected — rounding each line independently can send more total tip
  // than the buyer chose (see computeTipsForLines).
  const lineTips = computeTipsForLines(
    state,
    state.products.map((item) => ({ price: item.price, permalink: item.permalink })),
  );
  const listedLineTips = paymentElementDirectListedCurrency
    ? computeTipsForLines(
        state,
        state.products.map((item) => ({
          price: item.listedChargePriceCents ?? item.listedPriceCents ?? item.price,
          permalink: item.permalink,
        })),
        { basis: "listed" },
      )
    : [];
  const exactPresentmentTipCurrency =
    state.tip.type === "fixed" && state.tip.presentmentAmount != null ? (state.tip.presentmentCurrency ?? null) : null;
  const requestedBuyerCurrency = state.buyerCurrency ?? exactPresentmentTipCurrency;
  const presentmentLineTips =
    state.tip.type === "fixed" &&
    state.tip.presentmentAmount != null &&
    requestedBuyerCurrency?.toLowerCase() === state.tip.presentmentCurrency?.toLowerCase()
      ? allocateFixedTipCents(
          state.tip.presentmentAmount,
          state.products.map((item) => ({ price: item.price })),
          getTotalPriceFromProducts(state),
        )
      : [];

  return getSurcharges(
    {
      products: state.products.map((item, index) => {
        const tipCents = item.hasFreeTrial && !isGift ? 0 : (lineTips[index] ?? 0);
        return {
          permalink: item.permalink,
          uid: item.uid,
          quantity: item.quantity,
          price: item.hasFreeTrial && !isGift ? 0 : Math.round(item.price + tipCents),
          tip_cents: tipCents,
          ...(paymentElementDirectListedCurrency && item.listedChargePriceCents != null
            ? { listed_price_cents: item.listedChargePriceCents }
            : {}),
          ...(paymentElementDirectListedCurrency && listedLineTips[index] != null
            ? { listed_tip_cents: listedLineTips[index] }
            : {}),
          ...(presentmentLineTips[index] != null ? { presentment_tip_cents: presentmentLineTips[index] } : {}),
          pay_in_installments: item.payInInstallments,
          subscription_id: item.subscription_id,
          recommended_by: item.recommended_by,
        };
      }),
      country: state.country,
      state: state.state,
      vat_id: state.vatId,
      postal_code: state.zipCode,
      ...(requestedBuyerCurrency ? { buyer_currency: requestedBuyerCurrency } : {}),
      ...(paymentDetailsSource ? { payment_details_source: paymentDetailsSource } : {}),
      ...(paymentElementMountCurrency ? { payment_element_mount_currency: paymentElementMountCurrency } : {}),
      ...(paymentElementDirectListedCurrency
        ? { payment_element_direct_listed_currency: paymentElementDirectListedCurrency }
        : {}),
      ...(state.checkoutPayment.integration === "payment_element_client_confirm" &&
      state.checkoutPayment.elements_options.payment_method_list_token
        ? { payment_method_list_token: state.checkoutPayment.elements_options.payment_method_list_token }
        : {}),
    },
    abortSignal,
  );
};

function validatePaymentMethodIndependentFields(state: State) {
  const errors = new Set<string>();
  const customFields = state.products.flatMap(({ permalink, customFields, bundleProductCustomFields }) => [
    ...customFields.map((field) => ({ ...field, key: getCustomFieldKey(field, { permalink }) })),
    ...bundleProductCustomFields.flatMap(({ product, customFields }) =>
      customFields.map((field) => ({
        ...field,
        key: getCustomFieldKey(field, { permalink, bundleProductId: product.id }),
      })),
    ),
  ]);
  for (const field of customFields) {
    if ((field.type === "terms" || field.required) && !state.customFieldValues[field.key])
      errors.add(`customFields.${field.key}`);
  }
  if (isTippingEnabled(state) && state.tip.type === "fixed" && state.tip.amount === null) errors.add("tip");
  if (
    requiresPayment(state) &&
    state.paymentMethod !== "stripePaymentRequest" &&
    !hasShipping(state) &&
    state.country === "US" &&
    !state.zipCode &&
    // The element's own pane collects the postal code when it collects the full billing
    // details (UPI on digital carts) — checkout's ZIP field is hidden then, so requiring it
    // would block the purchase on a field the buyer cannot see.
    !paymentElementCollectsFullBillingDetails(state)
  )
    errors.add("zipCode");
  // Stripe requires billing_details.name to confirm a UPI payment, and on the element-full
  // mode the pane's own name field is pinned to "never" — checkout's Full name field is the
  // only source (see paymentElementBillingDetailsOverride). Bancontact needs the name too
  // (Stripe: "your customer's name is required for the Bancontact authorization to succeed"),
  // but stays in "form" collection mode, so it isn't covered by the element-full check —
  // gumroad-private#1306. Without this gate a blank name reaches Stripe's confirm and fails
  // server-side with parameter_missing and no last_payment_error — the un-actionable failure
  // shape of gumroad-private#933.
  if (
    requiresPayment(state) &&
    (paymentElementCollectsFullBillingDetails(state) || paymentElementRequiresBillingNameForSelection(state)) &&
    !state.fullName
  )
    errors.add("fullName");
  if (state.gift?.type === "normal" && !isValidEmail(state.gift.email)) errors.add("gift");
  return errors;
}

/**
 * Finishes a submit that was refused only because the payment configuration was stale, once
 * everything it was waiting for has arrived.
 *
 * A refused submit is waiting on TWO things, and they can land in either order: the recomputed
 * payment configuration, and a loaded quote. Accepting an offer edits the cart, and a cart edit
 * resets the quote to pending, so the configuration commonly arrives first with the quote still in
 * flight. Both arrival sites call this, and whichever completes the pair performs the resume — the
 * other one finds a gate still open and leaves the resume armed.
 *
 * That "leave it armed" part is what keeps the offer pipeline from deadlocking. Consuming the flag
 * on the first arrival and bailing because the other gate was still closed is exactly how a buyer
 * ends up on the checkout page, Pay re-enabled, with the purchase they confirmed in the offer modal
 * never placed and no error shown.
 */
function resumeRefusedSubmitIfReady(state: State) {
  if (!state.resumeSubmitAfterCheckoutPayment) return;
  // Still waiting on the other half. Stay armed so the later arrival can finish the job.
  if (state.checkoutPaymentStale || state.surcharges.type !== "loaded") return;
  // Only resume a submit the buyer is still sitting in front of. Anything past "input" means the
  // pipeline already moved on under its own steam and does not need restarting.
  if (state.status.type !== "input") return;

  state.resumeSubmitAfterCheckoutPayment = false;
  // A resumed submit is not a free pass: it re-runs the same field validation a fresh submit does,
  // so an incomplete form lands back on "input" with the offending fields flagged.
  const resumeErrors = validatePaymentMethodIndependentFields(state);
  if (resumeErrors.size) state.validationFailedCount += 1;
  state.status = resumeErrors.size ? { type: "input", errors: resumeErrors } : { type: "validating" };
}

// Exported so checkout state transitions can be unit-tested without rendering the checkout.
export const reduceCheckoutState = produce((state: State, action: Action) => {
  switch (action.type) {
    case "set-value":
      if (
        ("country" in action && action.country !== state.country) ||
        // Any US zip edit invalidates: the server derives the taxable state and the TaxJar
        // destination from the postal code whenever the country is US, and the purchase payload
        // submits the current zip — so even a partial edit (or clearing the field) leaves the
        // loaded quote stale relative to what will be charged. The 300ms refetch debounce
        // already absorbs individual keystrokes.
        ("zipCode" in action && action.zipCode !== state.zipCode && state.country === "US") ||
        ("state" in action && action.state !== state.state && state.country === "CA") ||
        ("vatId" in action && action.vatId !== state.vatId) ||
        ("gift" in action && action.gift?.type !== state.gift?.type) ||
        ("buyerCurrency" in action && action.buyerCurrency !== state.buyerCurrency) ||
        ("usingSavedCard" in action && action.usingSavedCard !== state.usingSavedCard) ||
        "products" in action ||
        "tip" in action
      ) {
        // Hold the quote a currency change replaces, so the summary can keep its shape while the
        // new one is minted. A second change landing on top of an in-flight one keeps the snapshot
        // already held: that one is the last quote the buyer actually saw. Every other
        // invalidation edits the cart itself, which makes the old amounts wrong rather than stale.
        if ("buyerCurrency" in action) {
          if (state.surcharges.type === "loaded")
            state.buyerCurrencyRemint = {
              surcharges: state.surcharges.result,
              previousCurrency: loadedBuyerCurrency(state),
            };
          else if (state.buyerCurrencyRemint?.surfaceSwitch)
            // An explicit pick landing on top of a surface switch's in-flight remint: there is no
            // loaded quote to snapshot, but the held amounts still describe what the buyer saw.
            // Keep them and re-point the remint at this pick, so a refusal restores the selection
            // this pick replaced instead of skipping refusal/restore entirely.
            state.buyerCurrencyRemint = {
              ...state.buyerCurrencyRemint,
              previousCurrency: state.buyerCurrency,
              surfaceSwitch: false,
            };
        } else if ("usingSavedCard" in action) {
          // Switching surface re-asks the server which currencies it can charge, but it does not
          // touch the cart, so the loaded amounts are still the amounts. Hold them for the same
          // reason a currency change does: folding the Total row (and the picker under it) away
          // for the length of the round trip reads as a hang. Pay stays disabled until the
          // replacement lands — isSubmitDisabled reads `surcharges`, not this snapshot.
          if (state.surcharges.type === "loaded")
            state.buyerCurrencyRemint = {
              surcharges: state.surcharges.result,
              previousCurrency: state.buyerCurrency,
              surfaceSwitch: true,
              // Pre-toggle: `action` is only merged into state further down.
              previousUsingSavedCard: state.usingSavedCard,
            };
          state.unavailableBuyerCurrency = null;
        } else {
          state.buyerCurrencyRemint = null;
          // The refusal was about the cart being replaced here, so it no longer describes
          // anything. The next response says whether the new cart can be quoted in that currency.
          state.unavailableBuyerCurrency = null;
        }
        if (state.surcharges.type === "loading") state.surcharges.abort();
        state.surcharges = { type: "pending" };
        // The totals (and the buyer-currency quote token) the in-progress payment was built on
        // are no longer the totals that will be charged, so a payment already past "input" must
        // be cancelled — otherwise the payload built at the end of the pipeline reads a
        // different (or missing) quote than the one the buyer confirmed.
        //
        // Card payments only: the quote token is never attached to wallet or PayPal payments
        // (those charge canonical USD and display USD totals), so a stale quote cannot diverge
        // there. The wallet (Apple Pay / Google Pay) sheet in particular dispatches its own
        // address updates mid-payment — cancelling on those would break the sheet's
        // completion handshake.
        //
        // "finished" is the point of no return: reaching it fires the purchase request
        // (pay()/updateSubscription() run off a status effect), and that request cannot be
        // cancelled from here. Resetting "finished" back to "input" would not stop the charge —
        // it would only re-enable the Pay button while the first charge is still in flight,
        // inviting a second submission and a duplicate charge. So a total-affecting change
        // landing at "finished" leaves the status alone; the payment proceeds on the totals it
        // was built with (the running request captured its state when it started).
        if (state.status.type !== "input" && state.status.type !== "finished" && state.paymentMethod === "card")
          state.status = { type: "input", errors: new Set() };
      }
      if (state.status.type === "input") {
        for (const key in action) state.status.errors.delete(key);
      }
      if ("email" in action && action.email !== state.email) {
        state.emailTypoSuggestion = null;
      }
      Object.assign(state, action);
      if ("buyerCurrency" in action) {
        // Picking again retires the notice about the last refusal.
        state.unavailableBuyerCurrency = null;
        writeBuyerCurrencyPreference(state.buyerCurrency);
      }
      break;
    case "set-wallet-billing-address": {
      // The wallet (Apple Pay / Google Pay) sheet shares its billing address only after the
      // buyer approves the payment, so this always lands while the payment pipeline is at
      // "starting". It must invalidate the surcharges quote exactly like the matching
      // "set-value" edits would (the server derives the taxable location from these fields),
      // but it must NOT cancel the in-flight payment back to "input": the wallet lanes hold
      // the already-tokenized payment and resume it once the quote reloads — but only if the
      // recalculated total still matches what the wallet sheet showed the buyer (see
      // resolveHeldWalletPayment). Cancelling here would abort that held payment before the
      // hold is even registered, dropping every wallet payment whose billing address changes
      // the tax location. A plain "set-value" can't express this, because on the element
      // surfaces the wallet payment runs with paymentMethod "card" and the "set-value"
      // invalidation cancels any past-"input" card payment.
      const { country, zipCode, state: billingState } = action;
      if (
        country !== state.country ||
        // Mirrors the "set-value" US ZIP rule: ANY ZIP change invalidates (partial ZIPs and
        // ZIP+4 included), evaluated against the incoming country since it lands in the same
        // action.
        (country === "US" && zipCode !== state.zipCode) ||
        (country === "CA" && billingState !== state.state)
      ) {
        state.buyerCurrencyRemint = null;
        state.unavailableBuyerCurrency = null;
        if (state.surcharges.type === "loading") state.surcharges.abort();
        state.surcharges = { type: "pending" };
      }
      if (state.status.type === "input") {
        for (const key of ["country", "zipCode", "state"]) state.status.errors.delete(key);
      }
      Object.assign(state, { country, zipCode, state: billingState });
      break;
    }
    case "set-paypal-billing-address": {
      const { fullName, email } = action;
      const billingAddress = paypalBillingAddressForCheckout(action, state);
      const taxLocationChanged = paypalBillingAddressChangesTaxLocation(action, state);
      if (taxLocationChanged) {
        state.buyerCurrencyRemint = null;
        state.unavailableBuyerCurrency = null;
        if (state.surcharges.type === "loading") state.surcharges.abort();
        state.surcharges = { type: "pending" };
        state.resumeSubmitAfterCheckoutPayment = false;
        if (state.status.type !== "finished") state.status = { type: "input", errors: new Set() };
        state.warning =
          "PayPal updated your tax location. Review the updated total below, then click PayPal again to continue.";
      } else {
        state.warning = null;
      }
      if (state.status.type === "input") {
        for (const key of ["country", "zipCode", "state", "fullName", "email"]) state.status.errors.delete(key);
      }
      Object.assign(state, { ...billingAddress, fullName, ...(email ? { email } : {}) });
      break;
    }
    case "set-custom-field":
      if (state.status.type !== "input") return;
      state.customFieldValues[action.key] = action.value;
      state.status.errors.delete(`customFields.${action.key}`);
      break;
    case "add-payment-method":
      if (!state.availablePaymentMethods.some((method) => method.type === action.paymentMethod.type))
        state.availablePaymentMethods.push(action.paymentMethod);
      break;
    case "offer": {
      // Never start a payment on a stale total: while surcharges are pending/loading (or
      // errored), the on-screen totals and the buyer-currency quote token aren't the ones the
      // charge would use. The submit button is disabled in this window, but other dispatch
      // paths (wallets, offer pipeline, keyboard) must be refused here too.
      if (state.surcharges.type !== "loaded") {
        // A failed fetch would otherwise be terminal: the refetch effect only fires on
        // "pending", so nothing retries an errored fetch and every submit path stays refused —
        // the native PayPal button in particular remains clickable and would silently do
        // nothing forever. Resetting to "pending" queues a refetch, turning the buyer's retry
        // click into an actual retry.
        if (state.surcharges.type === "error") state.surcharges = { type: "pending" };
        // Keep any validation errors already on screen — the refusal isn't a revalidation, so
        // wiping the highlights here would clear them without recomputing until the next
        // real submit.
        state.status = { type: "input", errors: state.status.type === "input" ? state.status.errors : new Set() };
        return;
      }
      const errors = validatePaymentMethodIndependentFields(state);
      if (errors.size) state.validationFailedCount += 1;
      state.status = errors.size ? { type: "input", errors } : { type: "offering" };
      break;
    }
    case "validate": {
      // Same stale-total refusal as "offer". The offer pipeline dispatches "validate" from the
      // "offering" status, so the refusal must cancel back to "input" (not bail silently) —
      // otherwise the checkout would be stranded in a processing state with the button disabled.
      if (state.surcharges.type !== "loaded" || state.checkoutPaymentStale) {
        // Same error-recovery and error-preservation reasoning as the "offer" refusal above.
        // checkoutPaymentStale is refused for the same reason as unloaded surcharges: paying now
        // would pay through an element configured for the cart as it was before the edit. Accepting
        // an offer invalidates synchronously (see acceptOffer) precisely so this refusal sees it.
        if (state.surcharges.type === "error") state.surcharges = { type: "pending" };
        // Flag the buyer's own missing fields right now, rather than waiting for the refreshed
        // configuration to land and the resume to re-validate. Accepting a cross-sell adds that
        // product's required fields to the form, and the "validate" this refusal is handling is the
        // very dispatch that is supposed to point them out; deferring it means the buyer clicks
        // through the offer and gets a silent, unexplained pause on a checkout that looks complete.
        // The refusal itself is unchanged — the submit still does not proceed.
        const refusedErrors = validatePaymentMethodIndependentFields(state);
        // Remember to finish this submit once everything it is waiting for lands. The offer pipeline
        // dispatches "validate" as the last step of accepting an offer, so if the refusal were the
        // end of it the buyer's confirmed purchase would silently never be placed.
        //
        // Armed whenever staleness is *one* of the reasons, not only when it is the sole one. An
        // accepted offer edits the cart, and a cart edit resets the quote to pending, so the two
        // conditions almost always fire together here — requiring a loaded quote at this instant
        // meant the resume was never armed for the offer flow it exists to serve. The quote's own
        // refetch path is not bypassed: resumeRefusedSubmitIfReady waits for the quote to load and
        // re-runs full validation before the submit proceeds.
        //
        // Not armed when the form is incomplete: the buyer has to fix the flagged fields and press
        // Pay again anyway, and an armed resume would fire a submit they did not ask for the moment
        // the configuration lands — re-running validation, failing again, and clearing nothing.
        if (state.checkoutPaymentStale && refusedErrors.size === 0) state.resumeSubmitAfterCheckoutPayment = true;
        if (refusedErrors.size) state.validationFailedCount += 1;
        state.status = {
          type: "input",
          errors: refusedErrors.size
            ? refusedErrors
            : state.status.type === "input"
              ? state.status.errors
              : new Set<string>(),
        };
        return;
      }
      const errors = validatePaymentMethodIndependentFields(state);
      if (errors.size) state.validationFailedCount += 1;
      state.status = errors.size ? { type: "input", errors } : { type: "validating" };
      break;
    }
    case "start-payment":
      // Same stale-total refusal as "offer"/"validate". "start-payment" has no status
      // precondition and is dispatched unconditionally from effects — CustomerDetails fires it
      // whenever status reaches "validating", and the wallet payment-request watcher does the
      // same — so a total-affecting invalidation landing between "validate" and this action
      // would otherwise let the pipeline re-enter and build its payload on a quote that no
      // longer matches the totals the buyer confirmed. Card payments only, same reasoning as
      // the invalidation cancel above: other methods never attach the quote token, and the
      // wallet sheet manages its own mid-payment state.
      if (state.paymentMethod === "card" && (state.surcharges.type !== "loaded" || state.checkoutPaymentStale)) {
        // Same error-recovery and error-preservation reasoning as the "offer" refusal above.
        // checkoutPaymentStale joins the condition for the same reason it does in "validate":
        // the element on screen may have been configured for a different cart.
        if (state.surcharges.type === "error") state.surcharges = { type: "pending" };
        state.status = { type: "input", errors: state.status.type === "input" ? state.status.errors : new Set() };
        return;
      }
      state.status = { type: "starting" };
      break;
    case "acknowledge-email-typo":
      state.acknowledgedEmails.add(action.email);
      state.emailTypoSuggestion = null;
      break;
    case "cancel":
      // Cancelling clears a pending resume too: the buyer (or an error path) has backed out of the
      // submit, so a configuration refresh landing later must not restart it behind their back.
      state.resumeSubmitAfterCheckoutPayment = false;
      if (state.status.type === "input") return;
      state.status = { type: "input", errors: new Set() };
      break;
    case "set-recaptcha-response": {
      if (state.status.type !== "captcha") return;
      const recaptchaData = action.recaptchaResponse ? { recaptchaResponse: action.recaptchaResponse } : {};
      state.status = { ...state.status, type: "finished", ...recaptchaData };
      break;
    }
    case "retry-recaptcha-challenge":
      // Only from "finished" — the refused pay attempt — and only once. A fallback attempt that is
      // refused again is terminal, so a buyer can't be bounced through challenges indefinitely;
      // the server withholds the offer there too.
      if (state.status.type !== "finished" || state.status.challengeFallback) return;
      state.status = { type: "captcha", paymentMethod: state.status.paymentMethod, challengeFallback: true };
      break;
    case "set-payment-method": {
      if (state.status.type !== "starting") return;
      const errors = validatePaymentMethodIndependentFields(state);
      if (!isValidEmail(state.email)) errors.add("email");
      if (hasShipping(state)) {
        for (const field of addressFields) {
          if (!state[field]) errors.add(field);
        }
      }
      if (errors.size) state.validationFailedCount += 1;
      state.status = errors.size ? { type: "input", errors } : { type: "captcha", paymentMethod: action.paymentMethod };
      break;
    }
    case "update-products":
      state.products = action.products;
      state.buyerCurrencyRemint = null;
      state.unavailableBuyerCurrency = null;
      if (state.surcharges.type === "loading") state.surcharges.abort();
      state.surcharges = action.surcharges ? { type: "loaded", result: action.surcharges } : { type: "pending" };
      // Accepting a cross-sell updates the products mid-pipeline on purpose, and it always
      // arrives with a freshly loaded quote precomputed for the accepted cart (so the Apple Pay
      // sheet can show the new total synchronously) — that flow may continue. Any other product
      // update that lands after the payment pipeline has started leaves the quote pending, which
      // means the payload at the end of the pipeline would be built on totals the buyer never
      // confirmed — cancel back to "input", same as the total-affecting "set-value" path above.
      // "finished" is excluded for the same reason as there: the purchase request is already in
      // flight and un-cancellable, so resetting would only invite a duplicate submission.
      if (state.surcharges.type !== "loaded" && state.status.type !== "input" && state.status.type !== "finished")
        state.status = { type: "input", errors: new Set() };
      // The third place a refused submit can become ready. This one also matters for correctness
      // rather than just liveness: the resume re-runs field validation, and the required custom
      // fields it must check come from state.products. Resuming here — right after the accepted
      // offer's products land — means that validation sees the cross-sold product's fields instead
      // of the pre-offer product list, so a cart whose new item has unfilled required fields is
      // flagged rather than waved through.
      resumeRefusedSubmitIfReady(state);
      break;
    case "invalidate-checkout-payment":
      // A cart edit can move the cart to a different payment lane (a multi-seller cart becoming
      // single-seller is quotable, so it belongs on the buyer-currency element rather than the
      // canonical one), and the configuration on screen was computed for the cart before the
      // edit. Mark it stale until the server answers: isSubmitDisabled blocks Pay while it is,
      // so the buyer can't pay through an element mounted for a cart they no longer have.
      state.checkoutPaymentStale = true;
      // Drop any pending resume. A resume is only ever meant to finish the submit the buyer just
      // confirmed; if the cart has been edited again since, finishing it later would place an order
      // the buyer never pressed Pay for. Safe for the offer pipeline because acceptOffer dispatches
      // this invalidation *before* its "validate" (see acceptOffer), so the resume it wants is set
      // after this runs, not cleared by it.
      state.resumeSubmitAfterCheckoutPayment = false;
      break;
    case "update-checkout-payment":
      // Only while the buyer is still filling the form in. Once the payment pipeline has started,
      // the mounted element has been handed to Stripe: PaymentForm reads this configuration to
      // decide what to render and how to tokenize, so swapping it mid-flight could remount the
      // element under an in-progress tokenization, or move the charged amount out from under a
      // wallet sheet the buyer has already approved. The same reasoning the total-affecting
      // "set-value" and "update-products" cases use to leave a started payment alone.
      //
      // Dropping the update is safe because it cannot be the stale-making edit's own refresh: a
      // cart edit resets the pipeline to "input" (see "update-products" above), so a response
      // arriving past "input" belongs to a cart the buyer already committed to paying for. The
      // stale flag is deliberately left as-is — if it was set, Pay stays blocked until a refresh
      // lands in "input", which is the fail-closed direction.
      if (state.status.type !== "input") return;
      state.checkoutPayment = action.checkoutPayment;
      state.checkoutPaymentStale = false;
      resumeRefusedSubmitIfReady(state);
      break;
    case "surcharges-fetch-succeeded":
      // A response may only publish while its own loading state is still current. Reducer
      // dispatches are processed strictly in order, so by the time this action runs, every
      // invalidation that happened before the response (a total-affecting edit resetting to
      // "pending", or a newer fetch replacing the loading state with a new requestId) is
      // already reflected in the state — a stale response can never restore an old quote,
      // re-enable Pay on old totals, or clobber a newer request's loading state. This is why
      // the fence lives here rather than in a mutable ref in the fetch callback: a ref bumped
      // from a passive effect only updates after React flushes effects, leaving a window
      // where a stale response still saw the old value.
      if (state.surcharges.type !== "loading" || state.surcharges.requestId !== action.requestId) return;
      {
        const remint = state.buyerCurrencyRemint;
        state.buyerCurrencyRemint = null;
        state.surcharges = { type: "loaded", result: action.result };
        // The notice deliberately does NOT clear just because the menu lists that currency again.
        // The menu is built from settlement eligibility and only drops the currency the request
        // in hand tried, so the response that restores the previous selection lists the refused
        // one right back — clearing on it would erase the explanation a moment after showing it.
        // Only the buyer picking again, or a cart edit, retires the notice.
        // The buyer picked a currency and the response came back without it: this cart cannot be
        // quoted in it. Put the selection back where it was and record the refusal — moving the
        // buyer on to some third currency with no explanation is what must not happen.
        if (
          remint &&
          !remint.surfaceSwitch &&
          state.buyerCurrency != null &&
          offersBuyerCurrency(action.result, state.buyerCurrency) === false
        ) {
          state.unavailableBuyerCurrency = state.buyerCurrency;
          state.buyerCurrency = remint.previousCurrency;
          // The response in hand is the canonical-USD fallback the refused currency produced, so
          // the restored selection needs quoting again — but only when this same response says it
          // is still on offer. Asking again for a currency the server has just withdrawn would
          // refuse, restore, and ask again without end (a transient FX error withdraws every
          // currency, so the buyer's previous one can be gone too).
          const restored = state.buyerCurrency ?? action.result.detected_buyer_currency ?? null;
          if (
            restored != null &&
            restored !== (action.result.buyer_currency_quote?.currency ?? "usd") &&
            offersBuyerCurrency(action.result, restored)
          ) {
            state.buyerCurrencyRemint = remint;
            state.surcharges = { type: "pending" };
          }
        } else if (
          !remint &&
          state.buyerCurrency != null &&
          offersBuyerCurrency(action.result, state.buyerCurrency) === false
        ) {
          const detected = action.result.detected_buyer_currency ?? null;
          const replacement =
            detected != null && offersBuyerCurrency(action.result, detected)
              ? detected
              : (action.result.available_buyer_currencies?.[0]?.code ?? null);
          if (replacement != null) {
            state.buyerCurrency = replacement;
            if (
              replacement !== (action.result.buyer_currency_quote?.currency ?? "usd") &&
              offersBuyerCurrency(action.result, replacement)
            ) {
              state.surcharges = { type: "pending" };
            }
          }
        }
      }
      // A quote arriving is the other half of what a refused submit is waiting for. Accepting an
      // offer edits the cart, and a cart edit resets the quote to pending, so the refreshed payment
      // configuration usually lands while the quote is still in flight — this is where the resume
      // actually fires in that ordering.
      resumeRefusedSubmitIfReady(state);
      break;
    case "surcharges-fetch-failed":
      // Same fence as the success case: only the current request may flip the state to
      // "error". A stale failure must not surface a bogus alert or strand the checkout while
      // a fresher request is still loading.
      if (state.surcharges.type !== "loading" || state.surcharges.requestId !== action.requestId) return;
      // A currency the buyer chose whose quote never arrived. Put the selection back on the
      // currency the summary is still showing, so the picker and the amounts under it agree while
      // the "something went wrong" alert explains the rest. The snapshot stays: it is the last
      // quote the buyer saw, and it is the one they are being returned to.
      //
      // `unavailableBuyerCurrency` is deliberately NOT set: a request that never completed is not
      // the server saying it cannot charge that currency, and the notice must not claim it did.
      if (state.buyerCurrencyRemint && !state.buyerCurrencyRemint.surfaceSwitch) {
        state.buyerCurrency = state.buyerCurrencyRemint.previousCurrency;
      }
      state.surcharges = { type: "error" };
      break;
  }
});

export function createReducer(initial: {
  countries: Record<string, string>;
  usStates: string[];
  caProvinces: string[];
  tipOptions: number[];
  defaultTipOption: number;
  country: string | null;
  email: string;
  state: string | null;
  address: { street: string | null; city: string | null; zip: string | null } | null;
  savedCreditCard: SavedCreditCard | null;
  products: Product[];
  fullName?: string;
  payLabel?: string;
  recaptchaKey: string | null;
  recaptchaScoreBased?: boolean;
  recaptchaChallengeKey?: string | null;
  paypalClientId: string;
  gift: Gift | null;
  requireEmailTypoAcknowledgment: boolean;
  checkoutPayment?: CheckoutPaymentConfig;
}): readonly [State, React.Dispatch<PublicAction>] {
  const url = new URL(useOriginalLocation());
  const reducer = React.useReducer(reduceCheckoutState, null, (): State => {
    const customFieldValues: Record<string, string> = {};
    for (const product of initial.products) {
      for (const customField of product.customFields) {
        const value = url.searchParams.get(customField.name);
        if (value) {
          customFieldValues[getCustomFieldKey(customField, product)] = value;
        }
      }
    }
    return {
      fullName: "",
      ...initial,
      recaptchaScoreBased: initial.recaptchaScoreBased ?? false,
      recaptchaChallengeKey: initial.recaptchaChallengeKey ?? null,
      country: initial.country ?? "US",
      vatId: "",
      address: initial.address?.street ?? "",
      city: initial.address?.city ?? "",
      state: initial.state ?? "",
      email: url.searchParams.get("email") ?? initial.email,
      zipCode: initial.address?.zip ?? "",
      buyerCurrency: readBuyerCurrencyPreference(),
      buyerCurrencyRemint: null,
      unavailableBuyerCurrency: null,
      customFieldValues,
      surcharges: { type: "pending" },
      saveAddress: !!initial.address,
      gift: initial.gift,
      checkoutPayment: initial.checkoutPayment ?? {
        integration: "card_element",
        fallback_reason: "not_checkout",
        disable_wallets: false,
        request_apple_pay_merchant_tokens: false,
        payment_element_wallets: false,
        flat_payment_methods: false,
        elements_options: null,
      },
      paymentMethod: "card",
      paymentElementType: "card",
      checkoutPaymentStale: false,
      resumeSubmitAfterCheckoutPayment: false,
      validationFailedCount: 0,
      willSaveCard: false,
      // Matches PaymentForm's own default (`useState(!!state.savedCreditCard)`), so the summary is
      // correct on the very first render rather than only after PaymentForm mounts and syncs.
      usingSavedCard: !!initial.savedCreditCard,
      tip: { type: "percentage", percentage: initial.defaultTipOption },
      status: { type: "input", errors: new Set() },
      availablePaymentMethods: [],
      emailTypoSuggestion: null,
      // Seed with previously-dismissed addresses so a buyer who already said "No, my email is
      // right" on an earlier visit isn't asked about the same address again.
      acknowledgedEmails: loadAcknowledgedEmails(),
      requireEmailTypoAcknowledgment: initial.requireEmailTypoAcknowledgment,
    };
  });
  const [state, dispatch] = reducer;
  useRunOnce(() => {
    const url = new URL(window.location.href);
    if (url.pathname.startsWith(Routes.checkout_path())) return;
    const searchParams = new URLSearchParams([...url.searchParams].filter(([key]) => key === "_gl"));
    url.search = searchParams.toString();
    // TODO (sm17p) Replace with Inertia's router.replace once subscription manager page is migrated to Inertia
    // then remove the checkout-path early return above so this runs on checkout too.
    window.history.replaceState(window.history.state, "", url.toString());
  });

  // Numbers each surcharge fetch so the reducer can tell whether a response is still the
  // current one. Aborting the fetch is best-effort (the response may already be in the
  // microtask queue when a newer request starts or a total-affecting edit invalidates), so
  // each response is dispatched with its requestId and the reducer only publishes it while
  // the matching "loading" state is still in place. Keeping the fence inside the reducer —
  // instead of comparing against a ref here — means it participates in dispatch ordering: an
  // invalidating edit that dispatched before the response resolves is guaranteed to have
  // reset the state first, with no window where the stale response can still pass the check.
  const surchargesRequestId = React.useRef(0);
  const updateSurcharges = useDebouncedCallback(
    asyncVoid(async () => {
      if (!state.products.length) return;
      const requestId = ++surchargesRequestId.current;
      const abort = new AbortController();
      dispatch({
        type: "set-value",
        surcharges: { type: "loading", requestId, abort: () => abort.abort() },
      });
      try {
        const result = await loadSurcharges(state, abort.signal);
        dispatch({ type: "surcharges-fetch-succeeded", requestId, result });
      } catch (e) {
        if (e instanceof AbortError) return;
        assertResponseError(e);
        dispatch({ type: "surcharges-fetch-failed", requestId });
      }
    }),
    300,
  );
  React.useEffect(() => {
    if (state.surcharges.type === "pending") updateSurcharges();
    // The reducer flips surcharges to "error" only when the current fetch fails (stale
    // failures are dropped there), so surfacing the alert on that transition can't fire for
    // a request that was already superseded.
    if (state.surcharges.type === "error") showAlert("Sorry, something went wrong. Please try again.", "error");
  }, [state.surcharges]);

  return reducer;
}

export const StateContext = React.createContext<ReturnType<typeof createReducer> | null>(null);

export const useState = () => {
  const context = React.useContext(StateContext);
  assert(context != null, "Checkout StateContext is missing");
  return context;
};
