import { StripeError } from "@stripe/stripe-js";
import { cast } from "ts-safe-cast";

import { AnyPaymentMethodResult } from "$app/data/payment_method_result";
import { Discount } from "$app/parsers/checkout";
import { ProductNativeType } from "$app/parsers/product";
import { assertResponseError, request, ResponseError } from "$app/utils/request";
import { getConnectedAccountStripeInstance, getStripeInstance } from "$app/utils/stripe_loader";

import { ProductToAdd } from "$app/components/Checkout/cartState";

export type PurchasePaymentMethod = AnyPaymentMethodResult | { type: "not-applicable" };

export type SuccessfulLineItemResult = {
  success: true;
} & ConfirmedPurchaseResponse;

type LineItemPaymentErrorShort = { success: false; error_message?: string; updated_product?: ProductToAdd };
type LineItemPaymentErrorFull = {
  success: false;
  error_message: string;
  name: string | null;
  formatted_price: string | null;
  error_code: string | null;
  is_tax_mismatch: boolean;
  card_country: string | null;
  ip_country: string | null;
  updated_product: ProductToAdd | null;
};
export type ErrorLineItemResult = LineItemPaymentErrorFull | LineItemPaymentErrorShort;

export type LineItemResult = SuccessfulLineItemResult | ErrorLineItemResult;

export type LineItemUid = string;
type VariantOptionId = string;
export type CustomFields = { id: string; value: string | boolean }[];

export type PurchaseLineItemPayload = {
  permalink: string;
  uid: LineItemUid;
  isMultiBuy: boolean;
  isPreorder: boolean;
  isRental: boolean;
  perceivedPriceCents: number;
  priceCents: number;
  tipCents: number | null;
  quantity: number;
  priceRangeUnit: number | null;
  priceId: string | null;
  payInInstallments: boolean;
  perceivedFreeTrialDuration: {
    unit: "hour" | "week" | "month";
    amount: number;
  } | null;
  variants: VariantOptionId[];
  callStartTime: string | null;
  discountCode: string | null;
  recommendedBy: string | null;
  recommenderModelName: string | null;
  affiliateId: string | null;
  customFields: CustomFields;
  urlParameters: string | null;
  referrer: string;
  isPppDiscounted: boolean;
  acceptedOffer: { id: string; original_product_id?: string | null; original_variant_id?: string | null } | null;
  bundleProducts: { productId: string; quantity: number; variantId: string | null; customFields: CustomFields }[];
};
export type StartCartPurchaseRequestPayload = {
  paymentMethod: PurchasePaymentMethod;
  email: string;
  fullName: string;
  zipCode: string | null;
  state: string | null;
  shippingInfo: {
    save?: boolean;
    fullName: string;
    streetAddress: string;
    city: string;
    state: string;
    zipCode: string;
    country: string;
  } | null;
  taxCountryElection: string | null;
  vatId: string | null;
  giftInfo:
    | {
        gifteeEmail: string;
        giftNote: string;
      }
    | {
        gifteeId: string;
        giftNote: string;
      }
    | null;
  eventAttributes: {
    plugins: string | null;
    friend: string | null;
    url_parameters: string | null;
    locale: string | null;
  };
  lineItems: PurchaseLineItemPayload[];
  recaptchaResponse: string | null;
};

export type OfferCodes = { code: string; products: Record<string, Discount> }[];

export type CartPurchaseResult = {
  lineItems: Record<LineItemUid, LineItemResult>;
  canBuyerSignUp: boolean;
  offerCodes: OfferCodes;
};

export type PurchaseErrorResponse = {
  success: false;
  permalink?: string | null;
  error_message: string;
  name: string | null;
  formatted_price: string;
  // NOTE: could be enumerated, but maybe not. purchase_error_code.rb is heavy and not sure if we need that level of granularity on the frontend
  error_code: string | null;
  is_tax_mismatch: boolean;
  card_country: string | null;
  ip_country: string | null;
  updated_product: ProductToAdd | null;
};
type PurchaseRequiresCardSetupResponse = {
  success: true;
  requires_card_setup: true;
  client_secret: string;
  purchase: { id: string; stripe_connect_account_id: string | null };
};
type PurchaseRequiresCardActionResponse = {
  success: true;
  requires_card_action: true;
  client_secret: string;
  purchase: { id: string; stripe_connect_account_id: string | null };
};
export type ConfirmedPurchaseResponse = {
  success: true;
  domain: string;
  protocol: string;
  name: string;
  remaining: number | null;
  should_show_receipt: boolean;
  show_view_content_button_on_product_page: boolean;
  is_recurring_billing: boolean;
  is_physical: boolean;
  has_files: boolean;
  product_id: string;
  // this one contains the -full- URL, not just the permalink/custom permalink portion
  product_permalink: string;
  // while this contains only that
  permalink: string;
  is_gift_receiver_purchase: boolean;
  gift_receiver_text: string;
  is_gift_sender_purchase: boolean;
  gift_sender_text: string;
  content_url: string | null;
  redirect_token: string | null;
  url_redirect_external_id: string | null;
  price: string;
  id: string;
  seller_id: string;
  email: string | null;
  full_name: string | null;
  view_content_button_text: string;
  is_following: boolean | null;
  has_third_party_analytics: boolean;
  currency_type: string;
  non_formatted_price: number;
  subscription_has_lapsed: boolean;
  extra_purchase_notice: string | null;
  account_by_this_email_exists: boolean;
  display_product_reviews: boolean;
  test_purchase_notice?: string;
  product_rating?: number;
  has_shipping_to_show: boolean;
  shipping_amount: string;
  has_sales_tax_to_show: boolean;
  sales_tax_amount: string;
  non_formatted_seller_tax_amount: string;
  was_tax_excluded_from_price: boolean;
  sales_tax_label: string | null;
  has_sales_tax_or_shipping_to_show: boolean;
  total_price_including_tax_and_shipping: string;
  quantity: number;
  show_quantity: boolean;
  shipped?: boolean;
  tracking_url?: string | null;
  variants_displayable: string;
  twitter_share_url: string;
  twitter_share_text: string;
  license_key?: string;
  membership?: { tier_name: string; tier_description: string | null; manage_url: string };
  enabled_integrations: { circle: boolean; discord: boolean };
  bundle_products?: { id: string; content_url: string | null }[];
  native_type: ProductNativeType;
};

export const createPurchasesRequestData = (
  payload: StartCartPurchaseRequestPayload,
  purchase: Record<string, unknown>,
) => {
  const data: Record<string, unknown> = {
    plugins: payload.eventAttributes.plugins,
    friend: payload.eventAttributes.friend,
    url_parameters: payload.eventAttributes.url_parameters,
    locale: payload.eventAttributes.locale,
    email: payload.email,
    tax_country_election: payload.taxCountryElection || "",
    is_gift: payload.giftInfo != null,
    vat_id: payload.vatId || "",
    "g-recaptcha-response": payload.recaptchaResponse || "",
    purchase,
    line_items: payload.lineItems.map((lineItem) => ({
      uid: lineItem.uid,
      permalink: lineItem.permalink,
      is_multi_buy: lineItem.isMultiBuy,
      is_preorder: lineItem.isPreorder,
      is_rental: lineItem.isRental,
      perceived_price_cents: lineItem.perceivedPriceCents,
      price_cents: lineItem.priceCents,
      tip_cents: lineItem.tipCents,
      quantity: lineItem.quantity,
      price_range: lineItem.priceRangeUnit,
      price_id: lineItem.priceId,
      pay_in_installments: lineItem.payInInstallments,
      perceived_free_trial_duration: lineItem.perceivedFreeTrialDuration,
      accepted_offer: lineItem.acceptedOffer,
      bundle_products: lineItem.bundleProducts.map((bundleProduct) => ({
        product_id: bundleProduct.productId,
        quantity: bundleProduct.quantity,
        variant_id: bundleProduct.variantId,
        custom_fields: bundleProduct.customFields,
      })),
      variants: lineItem.variants,
      call_start_time: lineItem.callStartTime || "",
      discount_code: lineItem.discountCode || "",
      was_product_recommended: lineItem.recommendedBy != null,
      recommended_by: lineItem.recommendedBy || "",
      recommender_model_name: lineItem.recommenderModelName || "",
      affiliate_id: lineItem.affiliateId || "",
      url_parameters: lineItem.urlParameters,
      referrer: lineItem.referrer,
      is_purchasing_power_parity_discounted: lineItem.isPppDiscounted,
      custom_fields: lineItem.customFields,
    })),
  };
  if (payload.fullName) {
    purchase.full_name = payload.fullName;
  }
  if (payload.shippingInfo) {
    data.save_shipping_address = payload.shippingInfo.save;
    purchase.full_name = payload.shippingInfo.fullName;
    purchase.street_address = payload.shippingInfo.streetAddress;
    purchase.city = payload.shippingInfo.city;
    purchase.state = payload.shippingInfo.state;
    purchase.zip_code = payload.shippingInfo.zipCode;
    purchase.country = payload.shippingInfo.country;
  } else if (payload.taxCountryElection === "US") {
    purchase.zip_code = payload.zipCode || "";
  } else if (payload.taxCountryElection === "CA") {
    purchase.state = payload.state || "";
  }
  if (payload.giftInfo != null) {
    if ("gifteeId" in payload.giftInfo) {
      data.giftee_id = payload.giftInfo.gifteeId;
    } else {
      data.giftee_email = payload.giftInfo.gifteeEmail;
    }
    data.gift_note = payload.giftInfo.giftNote;
  }

  if (payload.paymentMethod.type !== "saved" && payload.paymentMethod.type !== "not-applicable") {
    const { cardParamsResult } = payload.paymentMethod;

    const paymentParams = cardParamsResult.cardParams;
    if (paymentParams.status === "success") {
      if (paymentParams.type === "card" || paymentParams.type === "payment-request") {
        data.stripe_payment_method_id = paymentParams.stripe_payment_method_id;
        data.card_country_source = paymentParams.card_country_source;
        data.card_country = paymentParams.card_country || "";

        if (paymentParams.type === "payment-request") {
          data.wallet_type = paymentParams.wallet_type;
        }

        if (paymentParams.reusable) {
          data.stripe_customer_id = paymentParams.stripe_customer_id;
          data.stripe_setup_intent_id = paymentParams.stripe_setup_intent_id;
        }
      }

      if (paymentParams.type === "paypal-native") {
        if (paymentParams.reusable) {
          data.billing_agreement_id = paymentParams.billing_agreement_id;
        } else {
          data.paypal_order_id = paymentParams.paypal_order_id;
        }
        data.visual = paymentParams.visual;
        data.card_country = paymentParams.card_country;
      }

      if (paymentParams.type === "paypal-braintree") {
        data.braintree_transient_customer_store_key = paymentParams.braintree_transient_customer_store_key || "";
        data.braintree_device_data = paymentParams.braintree_device_data ?? "";
      }
    } else {
      data.stripe_error = {
        type: paymentParams.stripe_error.type,
        message: paymentParams.stripe_error.message || "",
        code: paymentParams.stripe_error.code || "",
        charge: paymentParams.stripe_error.charge || "",
        decline_code: paymentParams.stripe_error.decline_code || "",
      };
    }
    if (cardParamsResult.type === "cc" || cardParamsResult.type === "paypal") {
      if (cardParamsResult.keepOnFile != null) {
        data.save_card = cardParamsResult.keepOnFile;
      }
    }
    if (cardParamsResult.type === "cc" && cardParamsResult.zipCode != null) {
      data.cc_zipcode_required = true;
      data.cc_zipcode = cardParamsResult.zipCode;
    }
  }
  return data;
};

// If we get a response that further user action is required for a line item payment (i.e. SCA)
// We need to trigger that action and confirm the payment
export const confirmLineItem = async (
  lineItemResult: PurchaseRequiresCardSetupResponse | PurchaseRequiresCardActionResponse,
): Promise<LineItemResult> => {
  try {
    const stripeConnectAccountId = lineItemResult.purchase.stripe_connect_account_id;
    const stripe = stripeConnectAccountId
      ? await getConnectedAccountStripeInstance(stripeConnectAccountId)
      : await getStripeInstance();
    let stripeResult;
    if ("requires_card_setup" in lineItemResult) {
      stripeResult = await stripe.confirmCardSetup(lineItemResult.client_secret);
    } else if ("requires_card_action" in lineItemResult) {
      stripeResult = await stripe.confirmCardPayment(lineItemResult.client_secret);
    } else {
      // TS can't figure out that the above condition is exhaustive
      throw new Error("Unreachable");
    }
    return await confirmPaymentAfterAction({
      purchaseId: lineItemResult.purchase.id,
      clientSecret: lineItemResult.client_secret,
      stripeError: stripeResult.error,
    });
  } catch (error) {
    assertResponseError(error);
    return { success: false };
  }
};

// SCA for single-product purchases may require further user action
// This endpoint is used to confirm the purchase after the action had been performed
const confirmPaymentAfterAction = async ({
  purchaseId,
  clientSecret,
  stripeError,
}: {
  purchaseId: string;
  clientSecret: string;
  stripeError: StripeError | undefined;
}): Promise<LineItemResult> => {
  const response = await request({
    method: "POST",
    url: Routes.confirm_purchase_path(purchaseId),
    accept: "json",
    data: {
      client_secret: clientSecret,
      stripe_error: stripeError,
    },
  });
  if (!response.ok) throw new ResponseError();
  return cast<LineItemResult>(await response.json());
};
