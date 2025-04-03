import { StripeError } from "@stripe/stripe-js";
import { cast } from "ts-safe-cast";

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
  return cast<OrderSuccessResponse | OrderErrorResponse>(await response.json());
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
  return cast<ConfirmOrderResponse>(await response.json());
};
