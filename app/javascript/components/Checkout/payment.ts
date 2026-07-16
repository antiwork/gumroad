import { enableMapSet, produce } from "immer";
import { groupBy } from "lodash-es";
import * as React from "react";

import { getSurcharges, SurchargesResponse } from "$app/data/customer_surcharge";
import { PurchasePaymentMethod } from "$app/data/purchase";
import { SavedCreditCard } from "$app/parsers/card";
import { CustomFieldDescriptor, ProductNativeType } from "$app/parsers/product";
import { assert } from "$app/utils/assert";
import { isValidEmail } from "$app/utils/email";
import { calculateFirstInstallmentPaymentPriceCents } from "$app/utils/price";
import { asyncVoid } from "$app/utils/promise";
import { RecurrenceId } from "$app/utils/recurringPricing";
import { AbortError, assertResponseError } from "$app/utils/request";

import { loadAcknowledgedEmails } from "$app/components/Checkout/acknowledgedEmails";
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
  // True when the server chose the buyer-currency presentment lane (a single USD-priced
  // one-time item from a seller in the buyer-currency rollout, for a buyer seeing local-currency
  // prices). The element then mounts in the currency of the FX quote from the surcharge
  // response — the same quote whose signed token prices the charge — so the payment sheet and
  // the charged amount always come from one source. Without a usable quote (expired, errored,
  // or the buyer opted to save the card, which forces the canonical USD charge path) the
  // element mounts canonical USD, exactly as if this flag were false.
  buyer_currency_presentment: boolean;
  payment_method_types: ["card"];
  payment_method_creation: "manual";
  stripe_link_enabled: boolean;
};
// Client-confirm checkout mints a ConfirmationToken from the Payment Element, so it omits
// payment_method_creation and stays in one-time payment mode. The method list is
// server-resolved (Checkout::PaymentMethodResolver) and must match the deferred intent's;
// the browser never widens it — card and Link everywhere (stripe_link_enabled reflects the
// resolved set; Link auto-enables with the Payment Element, dropped only by the PPP gate), plus
// the US-locked methods (cashapp, us_bank_account) for US buyers.
// Currency is "usd" everywhere except the method-forced test-mode QA surface (iDEAL/Bancontact),
// where the server mounts the element in the payment method's forced currency (e.g. "eur") and
// supplies presentment_amount_cents — the single product's listed price in that currency — so
// Stripe shows the EUR-only method tabs (it hides methods that can't charge in the element's
// currency). When presentment_amount_cents is null the amount derives from the USD total below.
export type PaymentElementClientConfirmConfig = {
  stripe_elements_mode: typeof STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT;
  currency: string;
  presentment_amount_cents: number | null;
  payment_method_types: string[];
  stripe_link_enabled: boolean;
  stripe_connect_account_id: string | null;
};
// Every integration variant also carries `request_apple_pay_merchant_tokens` — a per-seller
// rollout flag: when true, subscription carts declare recurring intent on the Apple Pay sheet so
// Apple issues a device-independent merchant token (MPAN) instead of a device token. It applies
// to the wallet button regardless of which card integration is active.
export type CheckoutPaymentConfig =
  | {
      integration: "card_element";
      fallback_reason: string;
      disable_wallets: boolean;
      request_apple_pay_merchant_tokens: boolean;
      elements_options: null;
    }
  | {
      integration: "payment_element";
      fallback_reason: null;
      disable_wallets: boolean;
      request_apple_pay_merchant_tokens: boolean;
      elements_options: PaymentElementConfig;
    }
  | {
      integration: "payment_element_client_confirm";
      fallback_reason: null;
      disable_wallets: boolean;
      request_apple_pay_merchant_tokens: boolean;
      elements_options: PaymentElementClientConfirmConfig;
    };

export type Product = {
  permalink: string;
  name: string;
  creator: Creator;
  quantity: number;
  price: number;
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
  recommended_by?: string | null;
  shippableCountryCodes: string[];
};

export type Gift =
  | { type: "normal"; email: string; note: string }
  | { type: "anonymous"; id: string; name: string; note: string };

export type Tip = { type: "percentage"; percentage: number } | { type: "fixed"; amount: number | null };

export type State = {
  products: Product[];
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
  // Card checkouts that save the card charge canonically in PR 1 (no buyer-presentment), so
  // buyer-currency display and the quote token are suppressed while this is set.
  willSaveCard: boolean;
  savedCreditCard: SavedCreditCard | null;
  checkoutPayment: CheckoutPaymentConfig;
  status:
    | { type: "input"; errors: Set<string> }
    | { type: "offering" }
    | { type: "validating" }
    | { type: "starting" }
    | { type: "captcha"; paymentMethod: PurchasePaymentMethod }
    | { type: "finished"; recaptchaResponse?: string; paymentMethod: PurchasePaymentMethod };
  payLabel?: string;
  recaptchaKey: string | null;
  recaptchaScoreBased: boolean;
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
  | "willSaveCard"
  | "gift"
  | "payLabel"
  | "warning"
  | "tip"
  | "emailTypoSuggestion";

type PublicAction =
  | ({ type: "set-value" } & Partial<{ [key in SimpleValue]?: State[key] | undefined }>)
  | { type: "set-custom-field"; key: string; value: string }
  | { type: "add-payment-method"; paymentMethod: PaymentMethod }
  | { type: "offer" }
  | { type: "validate" }
  | { type: "start-payment" }
  | { type: "set-recaptcha-response"; recaptchaResponse?: string }
  | { type: "set-payment-method"; paymentMethod: PurchasePaymentMethod }
  | { type: "acknowledge-email-typo"; email: string }
  | {
      type: "update-products";
      products: Product[];
      surcharges?: SurchargesResponse;
    }
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
      (product) => !!product.recurrence || !!product.subscription_id || product.nativeType === "commission",
    )
  );
}

export function requiresReusablePaymentMethodForCardCollection(state: State, useStripePaymentElement: boolean) {
  if (!useStripePaymentElement) return requiresReusablePaymentMethod(state);
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

  // Rails chooses the initial lane, but discount/surcharge reloads can lower the final total before Elements updates.
  if (state.surcharges.type === "loaded") {
    const total = getTotalPrice(state);
    if (total === null || total < STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS) return false;
  }

  return !state.products.some((product) => product.payInInstallments || product.hasFreeTrial || product.isPreorder);
}

// The browser must not widen server eligibility for client-confirm: single-seller,
// one-time card checkouts only.
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

  return !state.products.some(
    (product) =>
      product.payInInstallments ||
      product.hasFreeTrial ||
      product.isPreorder ||
      !!product.recurrence ||
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
  // Method-forced test-mode QA surface: the element is mounted in the payment method's forced
  // currency (e.g. EUR for iDEAL/Bancontact), so the USD total below would be the wrong unit.
  // The server supplies the listed amount in the element's currency instead.
  if (
    state.checkoutPayment.integration === "payment_element_client_confirm" &&
    state.checkoutPayment.elements_options.presentment_amount_cents !== null
  )
    return state.checkoutPayment.elements_options.presentment_amount_cents;
  // Buyer-currency presentment lane: the element mounts in the quote currency, so the amount
  // must be the quote's locked local-currency total, not the USD total below.
  const presentment = getStripePaymentElementPresentment(state);
  if (presentment) return presentment.amountCents;
  return getTotalPrice(state);
}

// The mount currency + amount for the buyer-currency presentment lane, or null everywhere else.
// Non-null only when the server chose the lane (buyer_currency_presentment on the server-confirm
// Payment Element config) AND the surcharge response carries a usable FX quote for this checkout.
// Both the element mount and the charge derive from that one quote — the element shows the
// buyer the exact local-currency amount whose signed token the server verifies at charge time.
// When the quote is missing or suppressed (expired/errored quote, or the buyer chose to save
// the card, which PR 1 forces onto the canonical USD charge path), this returns null and the
// element mounts canonical USD — matching the canonical charge the fallback performs.
export function getStripePaymentElementPresentment(state: State): { currency: string; amountCents: number } | null {
  if (state.checkoutPayment.integration !== "payment_element") return null;
  if (!state.checkoutPayment.elements_options.buyer_currency_presentment) return null;
  if (state.surcharges.type !== "loaded") return null;

  const quote = state.surcharges.result.buyer_currency_quote;
  // Mirrors the display/token gate (getCheckoutBuyerCurrencyDisplay): saving a card or
  // selecting a non-card payment method (PayPal) charges canonically, so the element must
  // not present local currency the buyer won't be charged.
  if (!quote || state.willSaveCard || state.paymentMethod !== "card") return null;

  return { currency: quote.currency, amountCents: quote.presentment_total_cents };
}

// The currency the server-confirm Payment Element should mount in, or null while it cannot be
// known. On the buyer-currency presentment lane the currency lives in the FX quote of the
// surcharge response, and every surcharge refresh (tip, address, VAT ID, or cart edits) passes
// through pending/loading states with no quote. Returning null in that window — rather than
// prematurely reporting canonical USD — lets PaymentElementInput keep the last mounted
// currency, because a currency change destroys and recreates the Stripe element (it is part of
// the Elements provider key), wiping any card details the buyer already entered. Definite
// canonical states (a loaded response without a quote, or the buyer opting to save the card)
// return "usd" so those transitions genuinely remount.
export function getStripePaymentElementMountCurrency(state: State): string | null {
  if (state.checkoutPayment.integration !== "payment_element") return null;
  const elementsOptions = state.checkoutPayment.elements_options;
  if (!elementsOptions.buyer_currency_presentment) return elementsOptions.currency;
  if (state.surcharges.type !== "loaded") return null;
  return getStripePaymentElementPresentment(state)?.currency ?? elementsOptions.currency;
}

export function isProcessing(state: State) {
  return state.status.type !== "input";
}

export function isSubmitDisabled(state: State) {
  const emailTypoBlocking = state.requireEmailTypoAcknowledgment && state.emailTypoSuggestion !== null;
  return isProcessing(state) || state.surcharges.type !== "loaded" || emailTypoBlocking;
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

export function getTotalPrice(state: State) {
  return state.surcharges.type === "loaded"
    ? state.surcharges.result.subtotal + state.surcharges.result.tax_cents + state.surcharges.result.shipping_rate_cents
    : null;
}

// The pre-tax sum of all future (not-charged-today) installment payments in the cart — the
// checkout table's "Future installments" row. Tips are excluded because the full tip amount is
// charged upfront with the first payment; taxes are excluded because the checkout table
// presents the full tax amount as part of "Payment today".
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

// What the buyer pays TODAY as the checkout table presents it ("Payment today"): the cart's full
// value minus the future installment payments. Wallet payment sheets (Apple Pay / Google Pay)
// display this as their total, so it must match the table the buyer just read — a single source
// of numbers for both, derived from the same server surcharges quote the table renders.
export function getChargeTodayPrice(state: State) {
  const total = getTotalPrice(state);
  if (total === null) return null;
  return total - getFutureInstallmentsTotal(state);
}

export function getCustomFieldKey(
  field: CustomFieldDescriptor,
  product: { permalink: string; bundleProductId?: string | null },
) {
  return field.collect_per_product ? `${product.permalink}-${product.bundleProductId ?? ""}-${field.id}` : field.id;
}

export const hasShipping = (state: State) => state.products.some((item) => item.requireShipping);

export const getErrors = (state: State) => (state.status.type === "input" ? state.status.errors : new Set());

export const loadSurcharges = (state: State, abortSignal?: AbortSignal) => {
  const isGift = state.gift !== null;

  return getSurcharges(
    {
      products: state.products.map((item) => ({
        permalink: item.permalink,
        quantity: item.quantity,
        price:
          item.hasFreeTrial && !isGift
            ? 0
            : Math.round(item.price + (computeTipForPrice(state, item.price, item.permalink) ?? 0)),
        subscription_id: item.subscription_id,
        recommended_by: item.recommended_by,
      })),
      country: state.country,
      state: state.state,
      vat_id: state.vatId,
      postal_code: state.zipCode,
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
    !state.zipCode
  )
    errors.add("zipCode");
  if (state.gift?.type === "normal" && !isValidEmail(state.gift.email)) errors.add("gift");
  return errors;
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
        "products" in action ||
        "tip" in action
      ) {
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
      break;
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
      state.status = errors.size ? { type: "input", errors } : { type: "offering" };
      break;
    }
    case "validate": {
      // Same stale-total refusal as "offer". The offer pipeline dispatches "validate" from the
      // "offering" status, so the refusal must cancel back to "input" (not bail silently) —
      // otherwise the checkout would be stranded in a processing state with the button disabled.
      if (state.surcharges.type !== "loaded") {
        // Same error-recovery and error-preservation reasoning as the "offer" refusal above.
        if (state.surcharges.type === "error") state.surcharges = { type: "pending" };
        state.status = { type: "input", errors: state.status.type === "input" ? state.status.errors : new Set() };
        return;
      }
      const errors = validatePaymentMethodIndependentFields(state);
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
      if (state.paymentMethod === "card" && state.surcharges.type !== "loaded") {
        // Same error-recovery and error-preservation reasoning as the "offer" refusal above.
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
      if (state.status.type === "input") return;
      state.status = { type: "input", errors: new Set() };
      break;
    case "set-recaptcha-response": {
      if (state.status.type !== "captcha") return;
      const recaptchaData = action.recaptchaResponse ? { recaptchaResponse: action.recaptchaResponse } : {};
      state.status = { ...state.status, type: "finished", ...recaptchaData };
      break;
    }
    case "set-payment-method": {
      if (state.status.type !== "starting") return;
      const errors = validatePaymentMethodIndependentFields(state);
      if (!isValidEmail(state.email)) errors.add("email");
      if (hasShipping(state)) {
        for (const field of addressFields) {
          if (!state[field]) errors.add(field);
        }
      }
      state.status = errors.size ? { type: "input", errors } : { type: "captcha", paymentMethod: action.paymentMethod };
      break;
    }
    case "update-products":
      state.products = action.products;
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
      state.surcharges = { type: "loaded", result: action.result };
      break;
    case "surcharges-fetch-failed":
      // Same fence as the success case: only the current request may flip the state to
      // "error". A stale failure must not surface a bogus alert or strand the checkout while
      // a fresher request is still loading.
      if (state.surcharges.type !== "loading" || state.surcharges.requestId !== action.requestId) return;
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
      country: initial.country ?? "US",
      vatId: "",
      address: initial.address?.street ?? "",
      city: initial.address?.city ?? "",
      state: initial.state ?? "",
      email: url.searchParams.get("email") ?? initial.email,
      zipCode: initial.address?.zip ?? "",
      customFieldValues,
      surcharges: { type: "pending" },
      saveAddress: !!initial.address,
      gift: initial.gift,
      checkoutPayment: initial.checkoutPayment ?? {
        integration: "card_element",
        fallback_reason: "not_checkout",
        disable_wallets: false,
        request_apple_pay_merchant_tokens: false,
        elements_options: null,
      },
      paymentMethod: "card",
      willSaveCard: false,
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
