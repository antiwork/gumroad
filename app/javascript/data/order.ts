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
type OrderErrorResponse = { success: false; error_message: string; recaptcha_challenge_available?: boolean };

export const mergeOfferCodes = (...groups: OfferCodes[]): OfferCodes =>
  Array.from(
    groups
      .flat()
      .reduce((merged, offerCode) => {
        const key = offerCode.code.normalize("NFC").trim().toLowerCase();
        const current = merged.get(key);
        merged.set(key, current ? { ...current, products: { ...current.products, ...offerCode.products } } : offerCode);
        return merged;
      }, new Map<string, OfferCodes[number]>())
      .values(),
  );

const offerCodesForPermalinks = (offerCodes: OfferCodes, permalinks: Set<string>): OfferCodes =>
  offerCodes.flatMap((offerCode) => {
    const products = Object.fromEntries(
      Object.entries(offerCode.products).filter(([permalink]) => permalinks.has(permalink)),
    );
    return Object.keys(products).length > 0 ? [{ ...offerCode, products }] : [];
  });

export const offerCodesForFailedLineItems = (
  requestData: StartCartPurchaseRequestPayload,
  lineItems: Partial<Record<LineItemUid, { success: boolean }>>,
  offerCodes: OfferCodes,
): OfferCodes => {
  const failedPermalinks = new Set(
    requestData.lineItems.filter((lineItem) => !lineItems[lineItem.uid]?.success).map((lineItem) => lineItem.permalink),
  );
  return offerCodesForPermalinks(offerCodes, failedPermalinks);
};

const offerCodesForPaymentConfirmationLineItems = (
  requestData: StartCartPurchaseRequestPayload,
  lineItems: Partial<Record<LineItemUid, { success: boolean; requires_payment_confirmation?: boolean }>>,
  offerCodes: OfferCodes,
) => {
  const pendingPermalinks = new Set(
    requestData.lineItems
      .filter((lineItem) => lineItems[lineItem.uid]?.requires_payment_confirmation)
      .map((lineItem) => lineItem.permalink),
  );
  return offerCodesForPermalinks(offerCodes, pendingPermalinks);
};

const offerCodesForSCALineItems = (
  requestData: StartCartPurchaseRequestPayload,
  lineItems: Partial<Record<LineItemUid, LineItemResponse>>,
  offerCodes: OfferCodes,
) => {
  const pendingPermalinks = new Set(
    requestData.lineItems
      .filter((lineItem) => {
        const result = lineItems[lineItem.uid];
        return result ? doesLineItemRequireSCA(result) : false;
      })
      .map((lineItem) => lineItem.permalink),
  );
  return offerCodesForPermalinks(offerCodes, pendingPermalinks);
};

const retryOfferCodeCandidates = (requestData: StartCartPurchaseRequestPayload, offerCodes: OfferCodes) =>
  offerCodes.map((offerCode) => ({
    code: offerCode.code,
    products: Object.fromEntries(
      requestData.lineItems
        .filter((lineItem) => offerCode.products[lineItem.permalink])
        .map((lineItem) => [lineItem.uid, { permalink: lineItem.permalink, quantity: lineItem.quantity }]),
    ),
  }));

// Initiates a request to create an order to purchase all the line items in the cart.
// Handles SCA actions where appropriate.
// Result object is guaranteed to have a result for each line item in the request.
export const startOrderCreation = async (
  requestData: StartCartPurchaseRequestPayload,
  activeOfferCodes: OfferCodes = [],
): Promise<CartPurchaseResult> => {
  let pendingOrderId: string | null = null;
  let pendingProcessorIntentId: string | null = null;
  let retryOfferCodes = activeOfferCodes;
  try {
    const response = await createOrder(requestData);
    if (!response.success) {
      return translateOrderFailureResponseIntoLineItemFailures(requestData, response, activeOfferCodes);
    }
    retryOfferCodes = mergeOfferCodes(
      offerCodesForSCALineItems(requestData, response.line_items, activeOfferCodes),
      response.offer_codes,
    );
    const lineItemRequiringSCA =
      Object.values(response.line_items).find(
        (lineItem): lineItem is OrderRequiresCardSetupResponse | OrderRequiresCardActionResponse =>
          doesLineItemRequireSCA(lineItem),
      ) ?? null;
    if (lineItemRequiringSCA) {
      const orderId = lineItemRequiringSCA.order.id;
      pendingOrderId = orderId;
      const clientSecret = lineItemRequiringSCA.client_secret;
      pendingProcessorIntentId = clientSecret.split("_secret")[0] ?? null;
      const stripeConnectAccountId = lineItemRequiringSCA.order.stripe_connect_account_id;
      const requiresCardAction = "requires_card_action" in lineItemRequiringSCA;
      const orderConfirmResponse = await confirmOrder(
        orderId,
        clientSecret,
        stripeConnectAccountId,
        requiresCardAction,
        retryOfferCodeCandidates(requestData, retryOfferCodes),
      );
      // Key by uid, not permalink, which collides when the cart holds two variants of one product.
      // The legacy confirm endpoint (Order::ConfirmService) still keys its line items by
      // purchase id, which matches no cart uid — fall back to permalink matching for those
      // responses, or every SCA outcome (including its error_message) is silently dropped and
      // the buyer sees the generic "Sorry, something went wrong." copy.
      const confirmLineItemResults = Object.values(orderConfirmResponse.line_items);
      const lineItems = requestData.lineItems.reduce<CartPurchaseResult["lineItems"]>((lineItems, lineItem) => {
        const resultItem =
          orderConfirmResponse.line_items[lineItem.uid] ??
          confirmLineItemResults.find((item) => item.permalink === lineItem.permalink);
        if (resultItem) lineItems[lineItem.uid] = resultItem;
        return lineItems;
      }, {});
      const result = {
        lineItems,
        canBuyerSignUp: response.can_buyer_sign_up,
        offerCodes: offerCodesForFailedLineItems(requestData, lineItems, orderConfirmResponse.offer_codes),
      };
      return ensureValidCartResult(requestData, result);
    }
    return translateOrderSuccessIntoLineItemSuccess(response);
  } catch (error) {
    // Treat parsing errors, timeout, etc as failed purchase, but print a log entry
    // eslint-disable-next-line no-console
    console.error("Error occurred processing order", error);
    if (pendingOrderId) {
      const unavailableOncePerCartIds = await reportClientConfirmError(
        pendingOrderId,
        "confirm",
        error instanceof Error ? error : new Error("Unknown confirmation error"),
        null,
        pendingProcessorIntentId,
      );
      retryOfferCodes = withoutUnavailableOncePerCartOfferCodes(retryOfferCodes, unavailableOncePerCartIds);
    }
    const result: CartPurchaseResult = {
      lineItems: requestData.lineItems.reduce<CartPurchaseResult["lineItems"]>(
        (lineItems, lineItem) => ({ ...lineItems, [lineItem.uid]: { success: false } }),
        {},
      ),
      canBuyerSignUp: false,
      offerCodes: retryOfferCodes,
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
  offerCodes: OfferCodes = [],
): CartPurchaseResult => ({
  lineItems: requestData.lineItems.reduce<CartPurchaseResult["lineItems"]>(
    (lineItems, lineItem) => ({
      ...lineItems,
      [lineItem.uid]: { success: false, error_message: cartResponse.error_message },
    }),
    {},
  ),
  canBuyerSignUp: false,
  offerCodes,
  recaptchaChallengeAvailable: cartResponse.recaptcha_challenge_available === true,
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
  retryOfferCodes: ReturnType<typeof retryOfferCodeCandidates>,
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
    retryOfferCodes,
  });
};

// SCA enabled cards may require further user action
// This endpoint is used to confirm the order after user has performed the required action
const confirmOrderAfterAction = async ({
  orderId,
  clientSecret,
  stripeError,
  retryOfferCodes,
}: {
  orderId: string;
  clientSecret: string;
  stripeError: StripeError | undefined;
  retryOfferCodes: ReturnType<typeof retryOfferCodeCandidates>;
}): Promise<ConfirmOrderResponse> => {
  const response = await request({
    method: "POST",
    url: Routes.confirm_order_path(orderId),
    accept: "json",
    data: {
      client_secret: clientSecret,
      stripe_error: stripeError,
      retry_offer_codes: retryOfferCodes,
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
export class PaymentConfirmedError extends Error {
  constructor(readonly returnUrl: string | null = null) {
    super();
  }
}

// Client-confirm order creation keeps the same CartPurchaseResult contract as startOrderCreation.
export const startClientConfirmOrderCreation = async (
  requestData: StartCartPurchaseRequestPayload,
  confirmationTokenId: string,
  // See PurchasePaymentMethod in ./purchase for why this is needed.
  selectedMethodType: string,
  activeOfferCodes: OfferCodes = [],
): Promise<CartPurchaseResult> => {
  let confirmedReturnUrl: string | null = null;
  let preparedOrderId: string | null = null;
  let preparedProcessorIntentId: string | null = null;
  let retryOfferCodes = activeOfferCodes;
  try {
    const prepareResponse = await prepareClientConfirmOrder(requestData, confirmationTokenId);
    if (!prepareResponse.success) {
      return translateOrderFailureResponseIntoLineItemFailures(requestData, prepareResponse, activeOfferCodes);
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
        offerCodesForFailedLineItems(requestData, prepareResponse.line_items, prepareResponse.offer_codes),
      );
    }

    retryOfferCodes = mergeOfferCodes(
      offerCodesForPaymentConfirmationLineItems(requestData, prepareResponse.line_items, activeOfferCodes),
      prepareResponse.offer_codes,
    );
    const { client_secret: clientSecret, order } = confirmationLineItem;
    preparedOrderId = order.id;
    preparedProcessorIntentId = clientSecret.split("_secret")[0] ?? null;
    const stripe = order.stripe_connect_account_id
      ? await getConnectedAccountStripeInstance(order.stripe_connect_account_id)
      : await getStripeInstance();

    // Never pass `elements` alongside `confirmation_token` — they are mutually exclusive in Stripe.js.
    const confirmResult = await stripe.confirmPayment({
      clientSecret,
      confirmParams: {
        confirmation_token: confirmationTokenId,
        return_url: Routes.checkout_return_url(order.id),
      },
      redirect: "if_required",
    });

    if (confirmResult.error) {
      const unavailableOncePerCartIds = await reportClientConfirmError(
        order.id,
        "confirm",
        confirmResult.error,
        selectedMethodType,
        clientSecret.split("_secret")[0] ?? null,
      );
      return translateOrderFailureResponseIntoLineItemFailures(
        requestData,
        {
          success: false,
          error_message: confirmResult.error.message ?? "Sorry, something went wrong.",
        },
        withoutUnavailableOncePerCartOfferCodes(retryOfferCodes, unavailableOncePerCartIds),
      );
    }

    // The card is captured from here on, so any later failure must surface as a distinct
    // "processing" outcome, never a resubmittable failure (which would risk a second charge).
    // The return page resolves a captured payment to its durable outcome (receipt, pending, or
    // failed-with-restored-cart), so every post-capture error carries its URL.
    confirmedReturnUrl = `${Routes.checkout_return_url(order.id)}?payment_intent=${encodeURIComponent(
      clientSecret.split("_secret")[0] ?? "",
    )}`;

    // Inline methods resolve in-page, then finalize via the (idempotent) AJAX endpoint.
    const finalizeResponse = await finalizeClientConfirmOrder(
      order.id,
      retryOfferCodeCandidates(requestData, retryOfferCodes),
    );

    // The card is captured, so any non-all-success finalize (processing, a per-line error, or empty)
    // must surface as processing, never a resubmittable failure. `[].every` is true, so guard empty.
    const lineItems = Object.values(finalizeResponse.line_items);
    const allSucceeded =
      lineItems.length > 0 && lineItems.every((lineItem) => lineItem.success && !("processing" in lineItem));
    if (!allSucceeded) throw new PaymentConfirmedError(confirmedReturnUrl);

    return mapResultsByUid(
      requestData,
      finalizeResponse.line_items,
      prepareResponse.can_buyer_sign_up,
      offerCodesForFailedLineItems(requestData, finalizeResponse.line_items, finalizeResponse.offer_codes),
    );
  } catch (error) {
    if (error instanceof PaymentConfirmedError) throw error;
    // eslint-disable-next-line no-console
    console.error("Error occurred processing client-confirm order", error);
    // A failure after the card was confirmed must not re-enable resubmission — the charge may be
    // captured. Surface it as a pending outcome; a pre-confirmation error is a normal failure.
    if (confirmedReturnUrl) throw new PaymentConfirmedError(confirmedReturnUrl);
    if (preparedOrderId) {
      const unavailableOncePerCartIds = await reportClientConfirmError(
        preparedOrderId,
        "confirm",
        error instanceof Error ? error : new Error("Unknown confirmation error"),
        selectedMethodType,
        preparedProcessorIntentId,
      );
      retryOfferCodes = withoutUnavailableOncePerCartOfferCodes(retryOfferCodes, unavailableOncePerCartIds);
    }
    return ensureValidCartResult(requestData, { lineItems: {}, canBuyerSignUp: false, offerCodes: retryOfferCodes });
  }
};

const withoutUnavailableOncePerCartOfferCodes = (
  offerCodes: OfferCodes,
  unavailableOncePerCartIds: ReadonlySet<string> | null,
): OfferCodes =>
  offerCodes.flatMap((offerCode) => {
    const products = Object.fromEntries(
      Object.entries(offerCode.products).filter(
        ([, discount]) =>
          !(
            discount.type === "fixed" &&
            discount.once_per_cart &&
            discount.once_per_cart_has_usage_limit &&
            (unavailableOncePerCartIds === null ||
              !discount.once_per_cart_id ||
              unavailableOncePerCartIds.has(discount.once_per_cart_id))
          ),
      ),
    );
    return Object.keys(products).length > 0 ? [{ ...offerCode, products }] : [];
  });

const CLIENT_CONFIRM_ERROR_TIMEOUT_MS = 5_000;

const reportClientConfirmError = async (
  orderId: string,
  stage: string,
  error: StripeError | Error,
  selectedMethodType: string | null,
  processorIntentId: string | null,
): Promise<ReadonlySet<string> | null> => {
  const abort = new AbortController();
  const timeout = setTimeout(() => abort.abort(), CLIENT_CONFIRM_ERROR_TIMEOUT_MS);
  try {
    const stripeError = "type" in error ? error : null;
    const response = await request({
      method: "POST",
      url: Routes.confirm_error_order_path(orderId),
      accept: "json",
      abortSignal: abort.signal,
      data: {
        stage,
        stripe_error_type: stripeError?.type ?? null,
        stripe_error_code: stripeError?.code ?? null,
        stripe_error_message: error.message ?? null,
        payment_method_type: stripeError?.payment_method?.type ?? null,
        selected_payment_method_type: selectedMethodType,
        processor_intent_id: processorIntentId,
      },
    });
    if (!response.ok) return null;

    const result: unknown = await response.json();
    if (
      typeof result === "object" &&
      result !== null &&
      "unavailable_once_per_cart_ids" in result &&
      Array.isArray(result.unavailable_once_per_cart_ids) &&
      result.unavailable_once_per_cart_ids.every((id): id is string => typeof id === "string")
    ) {
      return new Set(result.unavailable_once_per_cart_ids);
    }
    return null;
  } catch {
    return null;
  } finally {
    clearTimeout(timeout);
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
const finalizeClientConfirmOrder = async (
  orderId: string,
  retryOfferCodes: ReturnType<typeof retryOfferCodeCandidates>,
): Promise<FinalizeOrderResponse> => {
  const response = await request({
    method: "POST",
    url: Routes.finalize_order_path(orderId),
    accept: "json",
    data: { retry_offer_codes: retryOfferCodes },
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
