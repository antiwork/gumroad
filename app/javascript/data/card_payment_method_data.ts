import { PaymentRequestPaymentMethodEvent, Stripe, StripeCardElement, StripeElements } from "@stripe/stripe-js";
import typia from "typia";

import {
  CardPaymentMethodParams,
  PaymentRequestPaymentMethodParams,
  ReusableCardPaymentMethodParams,
  ReusablePaymentRequestPaymentMethodParams,
  StripeErrorParams,
  WalletPaymentMethodDetails,
} from "$app/data/payment_method_params";
import { request } from "$app/utils/request";
import { getStripeInstance } from "$app/utils/stripe_loader";

import { Product } from "$app/components/Checkout/payment";

type ReusableCCVariation<CardParams extends CardPaymentMethodParams | PaymentRequestPaymentMethodParams> =
  CardParams extends CardPaymentMethodParams
    ? ReusableCardPaymentMethodParams
    : CardParams extends PaymentRequestPaymentMethodParams
      ? ReusablePaymentRequestPaymentMethodParams
      : never;

type CardData = {
  cardElement: StripeCardElement | { token: string };
  email: string;
  zipCode?: string;
};
export const prepareCardPaymentMethodData = async (
  cardData: CardData,
): Promise<CardPaymentMethodParams | StripeErrorParams> => {
  const stripe = await getStripeInstance();

  const paymentMethodResult = await stripe.createPaymentMethod({
    type: "card",
    card: cardData.cardElement,
    billing_details: { address: { postal_code: cardData.zipCode ?? "" }, email: cardData.email },
  });

  if (paymentMethodResult.error) {
    return { status: "error", stripe_error: paymentMethodResult.error };
  }
  return cardPaymentMethodParams(paymentMethodResult.paymentMethod);
};

export type PaymentElementCardData = {
  stripe: Stripe;
  elements: StripeElements;
  email: string;
  fullName: string | null;
  zipCode: string | null;
  country: string | null;
  state: string | null;
  city: string | null;
  address: string | null;
  // Who collects the buyer's billing details for the selected payment-method row — see
  // paymentElementBillingDetailsCollection below for the three modes and why each exists.
  billingDetailsCollection: PaymentElementBillingDetailsCollection;
  // Wallet submissions only: the elements.submit() promise from the call made synchronously in
  // the buyer's click (see the wallet submit chain in PaymentForm.tsx). Safari only lets the
  // Apple Pay sheet open inside a user-activation window, and checkout's submission pipeline
  // reaches tokenization in an async effect several ticks after the click — far too late — so
  // the click handler submits the element itself and hands the in-flight promise here for
  // tokenization to await instead of calling elements.submit() a second time.
  pendingSubmit?: ReturnType<StripeElements["submit"]> | null;
};

// Payment-method types the Payment Element reports (via its change event's `value.type`) when
// the buyer selects a wallet row instead of the card form. Detection happens on the change
// event — i.e. before tokenization — because the billing-details decision has to be made when
// calling createPaymentMethod/createConfirmationToken; once the PaymentMethod exists with
// overridden billing details there is no way to un-clobber the wallet's own values.
const WALLET_PAYMENT_ELEMENT_TYPES = ["apple_pay", "google_pay"];
export const isWalletPaymentElementType = (type: string) => WALLET_PAYMENT_ELEMENT_TYPES.includes(type);

// Who collects the buyer's billing details for a given Payment Element selection. Checkout has
// its own fields (email, full name, country, ZIP...) so anything our form collects stays pinned
// to "never" on the element — each piece of information should only be asked for once.
// - "form": checkout's own form collects everything and tokenization passes its values
//   explicitly (cards, Link, iDEAL — and UPI on shippable carts, where the shipping form
//   already collects the full street address).
// - "element": the element supplies everything and tokenization passes no override. Wallets
//   only — the Apple Pay / Google Pay sheet carries the buyer's verified billing details, and
//   nothing extra is rendered on the page.
// - "element-address": the element renders ONLY the street-address fields; checkout's form
//   still owns email, name, and country. UPI on non-shippable carts: Stripe requires
//   `billing_details.name` and a full street address to confirm a UPI payment, and the digital
//   checkout form only collects email + name (+ ZIP for US buyers) — with every field pinned
//   to "never" the confirm always failed server-side with `parameter_missing` and buyers could
//   never complete a UPI purchase (the July 2026 UPI ramp-down, gumroad-private#933). Flipping
//   the whole block to "auto" instead would have Stripe re-ask for name and country inside the
//   UPI pane, duplicating checkout's own fields — so only the address fields our form doesn't
//   have are element-collected, and tokenization passes the form's email/name/country alongside.
export type PaymentElementBillingDetailsCollection = "form" | "element" | "element-address";
export const paymentElementBillingDetailsCollection = (
  type: string,
  hasShippingCart: boolean,
): PaymentElementBillingDetailsCollection => {
  if (isWalletPaymentElementType(type)) return "element";
  if (type === "upi" && !hasShippingCart) return "element-address";
  return "form";
};

// Client-side details about the wallet that paid through the Payment Element, read off the
// tokenized PaymentMethod (or ConfirmationToken preview). The billing address feeds the
// tax-location logic in checkout (the wallet sheet is the buyer's source of truth for wallet
// payments), and the wallet type is reported to the server for analytics.
type WalletPaymentMethodPayload = {
  billing_details?: { address?: { country: string | null; postal_code: string | null; state: string | null } | null };
  card?: { wallet?: Record<string, unknown> | null } | null;
};
const walletPaymentMethodDetails = (paymentMethod: WalletPaymentMethodPayload): WalletPaymentMethodDetails | null => {
  const walletType = paymentMethod.card?.wallet?.type;
  if (typeof walletType !== "string") return null;
  // Only Apple Pay / Google Pay count as wallet payments here. A card PaymentMethod can also
  // carry other card-wallet markers — notably Link in its card-passthrough mode, which is
  // enabled on the element independently of the payment_element_wallets flag. Link buyers type
  // their address into the Gumroad form like any card buyer (there is no wallet sheet supplying
  // a verified billing address), so treating Link as a wallet would wrongly report it as a
  // wallet payment to the server and feed form values back through the wallet tax-location path.
  if (!isWalletPaymentElementType(walletType)) return null;
  const address = paymentMethod.billing_details?.address;
  return {
    type: walletType,
    billingAddress: address
      ? { country: address.country, postal_code: address.postal_code, state: address.state }
      : null,
  };
};

type PaymentElementBillingDetailsData = Pick<
  PaymentElementCardData,
  "address" | "city" | "country" | "email" | "fullName" | "state" | "zipCode"
>;

export const paymentElementBillingDetails = (cardData: PaymentElementBillingDetailsData) => ({
  email: cardData.email,
  name: cardData.fullName || null,
  phone: null,
  address: {
    city: cardData.city || null,
    country: cardData.country || null,
    line1: cardData.address || null,
    line2: null,
    postal_code: cardData.zipCode || null,
    state: cardData.state || null,
  },
});

// Builds the billing_details override tokenization passes to Stripe (or null when it must pass
// none), per the collection mode above:
// - "form": the full checkout-form values — required, because every element field is "never".
// - "element": no override at all — the wallet sheet's verified details must survive, and
//   passing any value would clobber them on the resulting PaymentMethod.
// - "element-address": only the fields checkout's form still owns (email, name, country) —
//   Stripe merges these with the street-address fields the element collected. The form's
//   city/state/ZIP are NOT passed: for US buyers the form shows a ZIP field, and overriding
//   the element-collected postal code with it would corrupt the address the buyer typed into
//   the element's pane.
const paymentElementBillingDetailsOverride = (cardData: PaymentElementCardData) => {
  switch (cardData.billingDetailsCollection) {
    case "element":
      return null;
    case "element-address":
      return {
        email: cardData.email,
        name: cardData.fullName || null,
        phone: null,
        address: { country: cardData.country || null },
      };
    case "form":
      return paymentElementBillingDetails(cardData);
  }
};

export const preparePaymentElementPaymentMethodData = async (
  cardData: PaymentElementCardData,
): Promise<CardPaymentMethodParams | StripeErrorParams> => {
  // Reuse the click-time submit for wallet payments (see pendingSubmit above); everything else
  // submits here as before.
  const submitResult = await (cardData.pendingSubmit ?? cardData.elements.submit());
  if (submitResult.error) {
    return { status: "error", stripe_error: submitResult.error };
  }

  // For card payments the Payment Element pins every billingDetails field to "never" (checkout
  // collects them itself), which REQUIRES us to supply billing_details here. See
  // paymentElementBillingDetailsOverride for the wallet and UPI exceptions — where the element
  // collects some or all of the billing details itself, the corresponding form values must not
  // be passed or they would clobber what the buyer entered in the element.
  const billingDetailsOverride = paymentElementBillingDetailsOverride(cardData);
  const paymentMethodResult = await cardData.stripe.createPaymentMethod({
    elements: cardData.elements,
    ...(billingDetailsOverride
      ? {
          params: {
            billing_details: billingDetailsOverride,
          },
        }
      : {}),
  });

  if (paymentMethodResult.error) {
    return { status: "error", stripe_error: paymentMethodResult.error };
  }

  const walletDetails = walletPaymentMethodDetails(paymentMethodResult.paymentMethod);
  return {
    ...cardPaymentMethodParams(paymentMethodResult.paymentMethod),
    // When a wallet paid, surface its type and billing address so checkout can update the tax
    // location from the wallet's verified address and report the wallet type to the server.
    // The key is omitted entirely for card payments so the params object — which callers
    // spread into server requests (see prepareFutureCharges) — is unchanged for them.
    ...(walletDetails ? { wallet: walletDetails } : {}),
  };
};

export type PaymentElementConfirmationTokenResult =
  | {
      status: "success";
      confirmationTokenId: string;
      cardCountry: string | null;
      wallet: WalletPaymentMethodDetails | null;
    }
  | StripeErrorParams;

// Use a ConfirmationToken so the server can inspect card country before client confirmation.
export const createPaymentElementConfirmationToken = async (
  cardData: PaymentElementCardData,
): Promise<PaymentElementConfirmationTokenResult> => {
  // Reuse the click-time submit for wallet payments (see pendingSubmit above); everything else
  // submits here as before.
  const submitResult = await (cardData.pendingSubmit ?? cardData.elements.submit());
  if (submitResult.error) {
    return { status: "error", stripe_error: submitResult.error };
  }

  // Same billing-details collection rules as preparePaymentElementPaymentMethodData above (see
  // paymentElementBillingDetailsOverride): full form values for cards, none for wallets, and
  // email/name/country only for UPI where the element collected the street address.
  const confirmationBillingDetailsOverride = paymentElementBillingDetailsOverride(cardData);
  const result = await cardData.stripe.createConfirmationToken({
    elements: cardData.elements,
    ...(confirmationBillingDetailsOverride
      ? { params: { payment_method_data: { billing_details: confirmationBillingDetailsOverride } } }
      : {}),
  });

  if (result.error) {
    return { status: "error", stripe_error: result.error };
  }

  return {
    status: "success",
    confirmationTokenId: result.confirmationToken.id,
    cardCountry: result.confirmationToken.payment_method_preview.card?.country ?? null,
    wallet: walletPaymentMethodDetails(result.confirmationToken.payment_method_preview),
  };
};

type CardPaymentMethodPayload = {
  id: string;
  card?: {
    country?: string | null;
  } | null;
};
export const cardPaymentMethodParams = (paymentMethod: CardPaymentMethodPayload): CardPaymentMethodParams => ({
  status: "success",
  type: "card",
  reusable: false,
  stripe_payment_method_id: paymentMethod.id,
  card_country: paymentMethod.card?.country ?? null,
  card_country_source: "stripe",
});

export const preparePaymentRequestPaymentMethodData = (
  paymentRequestEvent: PaymentRequestPaymentMethodEvent,
): PaymentRequestPaymentMethodParams => {
  const paymentMethod = paymentRequestEvent.paymentMethod;
  return {
    status: "success",
    type: "payment-request",
    reusable: false,
    stripe_payment_method_id: paymentMethod.id,
    card_country: paymentMethod.card ? paymentMethod.card.country : null,
    card_country_source: "stripe",
    email: paymentMethod.billing_details.email,
    zip_code: paymentMethod.billing_details.address ? paymentMethod.billing_details.address.postal_code : null,
    wallet_type: typia.assert<string>(paymentMethod.card?.wallet?.type),
  };
};

export const confirmCardIfNeeded = async <
  CardParams extends CardPaymentMethodParams | PaymentRequestPaymentMethodParams,
>(
  data: PrepareFutureChargesResponse<CardParams>,
): Promise<ReusableCCVariation<CardParams> | StripeErrorParams> => {
  const cardParams = data.cardParams;

  if (cardParams.status === "success" && data.requiresCardSetup) {
    const stripe = await getStripeInstance();
    const result = await stripe.confirmCardSetup(data.requiresCardSetup.client_secret);
    if (result.error) {
      return { status: "error", stripe_error: result.error };
    }
    return cardParams;
  }
  return cardParams;
};

type PrepareFutureChargesRequest<CardParams extends CardPaymentMethodParams | PaymentRequestPaymentMethodParams> = {
  products: Product[];
  cardParams: CardParams;
};
type PrepareFutureChargesResponse<CardParams extends CardPaymentMethodParams | PaymentRequestPaymentMethodParams> =
  | {
      cardParams: ReusableCCVariation<CardParams>;
      requiresCardSetup: false | { client_secret: string };
    }
  | {
      cardParams: StripeErrorParams;
      requiresCardSetup: false;
    };
export const prepareFutureCharges = async <
  CardParams extends CardPaymentMethodParams | PaymentRequestPaymentMethodParams,
>(
  data: PrepareFutureChargesRequest<CardParams>,
): Promise<PrepareFutureChargesResponse<CardParams>> => {
  // The wallet details on the card params are client-side context (checkout tax location and
  // the wallet_type reported with the purchase) — the setup-intent endpoint has no contract for
  // them, so keep them out of the request body while preserving them on the returned reusable
  // params, which the purchase submission still needs.
  const { wallet: _wallet, ...setupIntentCardParams } = data.cardParams;
  const response = await request({
    method: "POST",
    url: Routes.stripe_setup_intents_path(),
    accept: "json",
    data: { ...setupIntentCardParams, products: data.products },
  });

  if (response.ok) {
    const responseData = typia.assert<CreateSetupIntentSuccessResponse>(await response.json());
    return {
      cardParams: {
        ...data.cardParams,
        stripe_customer_id: responseData.reusable_token,
        stripe_setup_intent_id: responseData.setup_intent_id,
        status: "success",
        reusable: true,
      },
      requiresCardSetup: "requires_card_setup" in responseData ? { client_secret: responseData.client_secret } : false,
    };
  }
  const responseData = typia.assert<CreateSetupIntentErrorResponse>(await response.json());
  return {
    cardParams: {
      stripe_error: {
        type: "api_error",
        message: responseData.error_message,
        ...(responseData.error_code ? { code: responseData.error_code } : {}),
      },
      status: "error",
    },
    requiresCardSetup: false,
  };
};
type CreateSetupIntentSuccessResponse =
  | { success: true; reusable_token: string; setup_intent_id: string; requires_card_setup: true; client_secret: string }
  | { success: true; reusable_token: string; setup_intent_id: string };
type CreateSetupIntentErrorResponse = { success: false; error_message: string; error_code?: string };
