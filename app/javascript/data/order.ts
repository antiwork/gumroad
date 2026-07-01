import { StripeError } from "@stripe/stripe-js";
import typia from "typia";

import {
  LineItemUid,
  CartPurchaseResult,
  StartCartPurchaseRequestPayload,
  PurchaseErrorResponse,
  ConfirmedPurchaseResponse,
  OfferCodes,
  createPurchasesRequestData,
} from "$app/data/purchase";
import { request, ResponseError } from "$app/utils/request";
import { getConnectedAccountStripeInstance, getStripeInstance } from "$app/utils/stripe_loader";

type OrderRequiresCardActionResponse = {
  success: true;
  requires_card_action: true;
  client_secret: string;
  order: { id: string; stripe_connect_account_id: string | null };
};
type OrderRequiresCardSetupResponse = {
  success: true;
  requires_card_setup: true;
  client_secret: string;
  order: { id: string; stripe_connect_account_id: string | null };
};
type LineItemResponse =
  | PurchaseErrorResponse
  | ConfirmedPurchaseResponse
  | OrderRequiresCardActionResponse
  | OrderRequiresCardSetupResponse;

type OrderSuccessResponse = {
  success: true;
  line_items: Record<LineItemUid, LineItemResponse>;
  can_buyer_sign_up: boolean;
  offer_codes: OfferCodes;
};
type ConfirmOrderResponse = {
  success: true;
  line_items: Record<LineItemUid, ConfirmedPurchaseResponse | PurchaseErrorResponse>;
  can_buyer_sign_up: boolean;
  offer_codes: OfferCodes;
};
type OrderErrorResponse = { success: false; error_message: string };

// Initiates a request to create an order to purchase all the line items in the cart.
// Handles SCA actions where appropriate.
// Result object is guaranteed to have a result for each line item in the request.
export const startOrderCreation = async (requestData: StartCartPurchaseRequestPayload): Promise<CartPurchaseResult> => {
  try {
    const response = await createOrder(requestData);
    if (!response.success) {
      return translateOrderFailureResponseIntoLineItemFailures(requestData, response);
    }
    const lineItemRequiringSCA =
      Object.values(response.line_items).find(
        (lineItem): lineItem is OrderRequiresCardSetupResponse | OrderRequiresCardActionResponse =>
          doesLineItemRequireSCA(lineItem),
      ) ?? null;
    if (lineItemRequiringSCA) {
      const orderId = lineItemRequiringSCA.order.id;
      const clientSecret = lineItemRequiringSCA.client_secret;
      const stripeConnectAccountId = lineItemRequiringSCA.order.stripe_connect_account_id;
      const requiresCardAction = "requires_card_action" in lineItemRequiringSCA;
      const orderConfirmResponse = await confirmOrder(
        orderId,
        clientSecret,
        stripeConnectAccountId,
        requiresCardAction,
      );
      const lineItemResults = Object.values(orderConfirmResponse.line_items);
      const result = {
        lineItems: requestData.lineItems.reduce<CartPurchaseResult["lineItems"]>((lineItems, lineItem) => {
          const resultItem = lineItemResults.find((item) => item.permalink === lineItem.permalink);
          if (resultItem) lineItems[lineItem.uid] = resultItem;
          return lineItems;
        }, {}),
        canBuyerSignUp: response.can_buyer_sign_up,
        offerCodes: response.offer_codes,
      };
      return ensureValidCartResult(requestData, result);
    }
    return translateOrderSuccessIntoLineItemSuccess(response);
  } catch (error) {
    // Treat parsing errors, timeout, etc as failed purchase, but print a log entry
    // eslint-disable-next-line no-console
    console.error("Error occurred processing order", error);
    const result: CartPurchaseResult = {
      lineItems: requestData.lineItems.reduce<CartPurchaseResult["lineItems"]>(
        (lineItems, lineItem) => ({ ...lineItems, [lineItem.uid]: { success: false } }),
        {},
      ),
      canBuyerSignUp: false,
      offerCodes: [],
    };
    return ensureValidCartResult(requestData, result);
  }
};

// Make sure that we have response entries for all line items, if not, fill them with errors
// So that consumers of this module can rely on all line items having a corresponding response entry
const ensureValidCartResult = (
  requestData: StartCartPurchaseRequestPayload,
  cartResult: CartPurchaseResult,
): CartPurchaseResult => {
  const validatedResult = {
    ...cartResult,
    canBuyerSignUp: cartResult.canBuyerSignUp,
    lineItems: { ...cartResult.lineItems },
  };

  requestData.lineItems.forEach((lineItem) => {
    validatedResult.lineItems[lineItem.uid] ??= { success: false };
  });

  return validatedResult;
};

// Turn global cart non-successful response into a result that has failed entries for every line item
const translateOrderFailureResponseIntoLineItemFailures = (
  requestData: StartCartPurchaseRequestPayload,
  cartResponse: OrderErrorResponse,
): CartPurchaseResult => ({
  lineItems: requestData.lineItems.reduce<CartPurchaseResult["lineItems"]>(
    (lineItems, lineItem) => ({
      ...lineItems,
      [lineItem.uid]: { success: false, error_message: cartResponse.error_message },
    }),
    {},
  ),
  canBuyerSignUp: false,
  offerCodes: [],
});

// Initiates order creation, which may or may not require further action
const createOrder = async (payload: StartCartPurchaseRequestPayload) => {
  const data = createPurchasesRequestData(payload, {});
  const response = await request({
    method: "POST",
    url: Routes.orders_path(),
    accept: "json",
    data,
  });
  if (!response.ok) throw new ResponseError();
  return typia.assert<OrderSuccessResponse | OrderErrorResponse>(await response.json());
};

const translateOrderSuccessIntoLineItemSuccess = (response: OrderSuccessResponse): CartPurchaseResult => ({
  lineItems: Object.entries(response.line_items).reduce<CartPurchaseResult["lineItems"]>(
    (responseLineItems, [uid, lineItem]) => ({
      ...responseLineItems,
      [uid]: doesLineItemRequireSCA(lineItem) ? { success: false } : lineItem,
    }),
    {},
  ),
  canBuyerSignUp: response.can_buyer_sign_up,
  offerCodes: response.offer_codes,
});

const doesLineItemRequireSCA = (
  lineItemResponse: LineItemResponse,
): lineItemResponse is OrderRequiresCardSetupResponse | OrderRequiresCardActionResponse =>
  lineItemResponse.success && ("requires_card_setup" in lineItemResponse || "requires_card_action" in lineItemResponse);

// If we get a response that further user action is required for the order (i.e. SCA),
// we need to trigger that action and confirm the order.
const confirmOrder = async (
  orderId: string,
  clientSecret: string,
  stripeConnectAccountId: string | null,
  requiresCardAction: boolean,
): Promise<ConfirmOrderResponse> => {
  let stripeError = undefined;

  const stripe = stripeConnectAccountId
    ? await getConnectedAccountStripeInstance(stripeConnectAccountId)
    : await getStripeInstance();

  if (requiresCardAction) {
    const stripeResult = await stripe.confirmCardPayment(clientSecret);
    stripeError = stripeResult.error;
  } else {
    const stripeResult = await stripe.confirmCardSetup(clientSecret);
    stripeError = stripeResult.error;
  }

  return confirmOrderAfterAction({
    orderId,
    clientSecret,
    stripeError,
  });
};

// SCA enabled cards may require further user action
// This endpoint is used to confirm the order after user has performed the required action
const confirmOrderAfterAction = async ({
  orderId,
  clientSecret,
  stripeError,
}: {
  orderId: string;
  clientSecret: string;
  stripeError: StripeError | undefined;
}): Promise<ConfirmOrderResponse> => {
  const response = await request({
    method: "POST",
    url: Routes.confirm_order_path(orderId),
    accept: "json",
    data: {
      client_secret: clientSecret,
      stripe_error: stripeError,
    },
  });
  if (!response.ok) throw new ResponseError();
  return typia.assert<ConfirmOrderResponse>(await response.json());
};

type OrderRequiresPaymentConfirmationResponse = {
  success: true;
  requires_payment_confirmation: true;
  client_secret: string;
  order: { id: string; stripe_connect_account_id: string | null };
};
type ProcessingPurchaseResponse = { success: true; processing: true; permalink: string };
type PrepareOrderResponse = {
  success: true;
  line_items: Record<
    LineItemUid,
    OrderRequiresPaymentConfirmationResponse | ConfirmedPurchaseResponse | PurchaseErrorResponse
  >;
  can_buyer_sign_up: boolean;
  offer_codes: OfferCodes;
};
// #finalize can return a `processing` line item when the PaymentIntent settles asynchronously,
// so it needs its own response type — reusing ConfirmOrderResponse would make typia.assert throw
// on the processing shape and misreport a captured payment as a failure.
type FinalizeOrderResponse = {
  success: true;
  line_items: Record<LineItemUid, ConfirmedPurchaseResponse | PurchaseErrorResponse | ProcessingPurchaseResponse>;
  can_buyer_sign_up: boolean;
  offer_codes: OfferCodes;
};

// Thrown once stripe.confirmPayment has captured the card but the order could not be finalized
// in-page (finalize kept failing, or the intent is still processing). The charge is real, so the
// consumer must surface a "processing" message and must NOT drop the buyer back into a
// resubmittable cart — retrying would create a second charge.
export class PaymentConfirmedError extends Error {}

// Client-confirm order creation keeps the same CartPurchaseResult contract as startOrderCreation.
export const startClientConfirmOrderCreation = async (
  requestData: StartCartPurchaseRequestPayload,
  confirmationTokenId: string,
): Promise<CartPurchaseResult> => {
  let paymentConfirmed = false;
  try {
    const prepareResponse = await prepareClientConfirmOrder(requestData, confirmationTokenId);
    if (!prepareResponse.success) {
      return translateOrderFailureResponseIntoLineItemFailures(requestData, prepareResponse);
    }

    const confirmationLineItem =
      Object.values(prepareResponse.line_items).find(
        (lineItem): lineItem is OrderRequiresPaymentConfirmationResponse =>
          lineItem.success && "requires_payment_confirmation" in lineItem,
      ) ?? null;

    if (!confirmationLineItem) {
      // No charge required (e.g. an all-free cart): the prepare responses are already final.
      return mapResultsByUid(
        requestData,
        prepareResponse.line_items,
        prepareResponse.can_buyer_sign_up,
        prepareResponse.offer_codes,
      );
    }

    const { client_secret: clientSecret, order } = confirmationLineItem;
    const stripe = order.stripe_connect_account_id
      ? await getConnectedAccountStripeInstance(order.stripe_connect_account_id)
      : await getStripeInstance();

    // Never pass `elements` alongside `confirmation_token` — they are mutually exclusive in Stripe.js.
    const confirmResult = await stripe.confirmPayment({
      clientSecret,
      confirmParams: { confirmation_token: confirmationTokenId },
      redirect: "if_required",
    });

    if (confirmResult.error) {
      return translateOrderFailureResponseIntoLineItemFailures(requestData, {
        success: false,
        error_message: confirmResult.error.message ?? "Sorry, something went wrong.",
      });
    }

    // The card is captured from here on, so any later failure must surface as a distinct
    // "processing" outcome, never a resubmittable failure (which would risk a second charge).
    paymentConfirmed = true;

    // Inline methods resolve in-page, then finalize via the (idempotent) AJAX endpoint.
    const finalizeResponse = await finalizeClientConfirmOrder(order.id);

    // The card is captured, so any non-all-success finalize (processing, a per-line error, or empty)
    // must surface as processing, never a resubmittable failure. `[].every` is true, so guard empty.
    const lineItems = Object.values(finalizeResponse.line_items);
    const allSucceeded =
      lineItems.length > 0 && lineItems.every((lineItem) => lineItem.success && !("processing" in lineItem));
    if (!allSucceeded) throw new PaymentConfirmedError();

    // offer_codes/can_buyer_sign_up are cart-level; finalize doesn't carry them, so keep prepare's.
    return mapResultsByUid(
      requestData,
      finalizeResponse.line_items,
      prepareResponse.can_buyer_sign_up,
      prepareResponse.offer_codes,
    );
  } catch (error) {
    if (error instanceof PaymentConfirmedError) throw error;
    // eslint-disable-next-line no-console
    console.error("Error occurred processing client-confirm order", error);
    // A failure after the card was confirmed must not re-enable resubmission — the charge may be
    // captured. Surface it as a pending outcome; a pre-confirmation error is a normal failure.
    if (paymentConfirmed) throw new PaymentConfirmedError();
    return ensureValidCartResult(requestData, { lineItems: {}, canBuyerSignUp: false, offerCodes: [] });
  }
};

const prepareClientConfirmOrder = async (
  payload: StartCartPurchaseRequestPayload,
  confirmationTokenId: string,
): Promise<PrepareOrderResponse | OrderErrorResponse> => {
  const data = { ...createPurchasesRequestData(payload, {}), confirmation_token: confirmationTokenId };
  const response = await request({ method: "POST", url: Routes.prepare_orders_path(), accept: "json", data });
  if (!response.ok) throw new ResponseError();
  return typia.assert<PrepareOrderResponse | OrderErrorResponse>(await response.json());
};

// No retry: a dropped finalize surfaces as "processing" and the webhook/worker finalize server-side.
const finalizeClientConfirmOrder = async (orderId: string): Promise<FinalizeOrderResponse> => {
  const response = await request({
    method: "POST",
    url: Routes.finalize_order_path(orderId),
    accept: "json",
    data: {},
  });
  if (!response.ok) throw new ResponseError();
  return typia.assert<FinalizeOrderResponse>(await response.json());
};

// #prepare and #finalize key line items by cart-item uid, so map by uid rather
// than permalink, which collides when the cart holds two variants of one product.
const mapResultsByUid = (
  requestData: StartCartPurchaseRequestPayload,
  lineItems: Record<
    LineItemUid,
    | OrderRequiresPaymentConfirmationResponse
    | ConfirmedPurchaseResponse
    | PurchaseErrorResponse
    | ProcessingPurchaseResponse
  >,
  canBuyerSignUp: boolean,
  offerCodes: OfferCodes,
): CartPurchaseResult =>
  ensureValidCartResult(requestData, {
    lineItems: Object.entries(lineItems).reduce<CartPurchaseResult["lineItems"]>((acc, [uid, result]) => {
      if (!("requires_payment_confirmation" in result) && !("processing" in result)) acc[uid] = result;
      return acc;
    }, {}),
    canBuyerSignUp,
    offerCodes,
  });
