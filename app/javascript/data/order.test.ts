import type { Stripe } from "@stripe/stripe-js";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { PaymentConfirmedError, startClientConfirmOrderCreation } from "$app/data/order";
import type { StartCartPurchaseRequestPayload } from "$app/data/purchase";
import { request } from "$app/utils/request";
import { getStripeInstance } from "$app/utils/stripe_loader";

vi.mock("$app/utils/request", () => ({
  ResponseError: class ResponseError extends Error {},
  request: vi.fn(),
}));

vi.mock("$app/utils/stripe_loader", () => ({
  getConnectedAccountStripeInstance: vi.fn(),
  getStripeInstance: vi.fn(),
}));

// typia's assert transform isn't wired into vitest.config, so stub it to a pass-through. These tests
// exercise the post-capture resubmission control flow, not response-shape validation.
vi.mock("typia", () => ({ default: { assert: (value: unknown) => value } }));

const requestMock = vi.mocked(request);
const getStripeInstanceMock = vi.mocked(getStripeInstance);

const jsonResponse = (body: unknown) => new Response(JSON.stringify(body), { status: 200 });

const requestData: StartCartPurchaseRequestPayload = {
  paymentMethod: {
    type: "payment-element-client-confirm",
    confirmationTokenId: "ct_123",
    cardCountry: "US",
    walletType: null,
    mountCurrency: "usd",
  },
  email: "buyer@example.com",
  fullName: "Buyer",
  zipCode: "10001",
  state: "NY",
  shippingInfo: null,
  taxCountryElection: null,
  vatId: null,
  giftInfo: null,
  eventAttributes: {
    plugins: null,
    friend: null,
    url_parameters: null,
    locale: "en-US",
  },
  recaptchaResponse: null,
  usedStripePaymentElement: true,
  lineItems: [
    {
      uid: "product-a ",
      permalink: "product-a",
      isMultiBuy: false,
      isPreorder: false,
      isRental: false,
      perceivedPriceCents: 1000,
      priceCents: 1000,
      tipCents: null,
      quantity: 1,
      priceRangeUnit: null,
      priceId: null,
      payInInstallments: false,
      perceivedFreeTrialDuration: null,
      variants: [],
      callStartTime: null,
      discountCode: null,
      recommendedBy: null,
      recommenderModelName: null,
      affiliateId: null,
      customFields: [],
      urlParameters: null,
      referrer: "direct",
      isPppDiscounted: false,
      forceNewSubscription: false,
      acceptedOffer: null,
      bundleProducts: [],
    },
  ],
};

const prepareResponse = {
  success: true,
  line_items: {
    "product-a ": {
      success: true,
      requires_payment_confirmation: true,
      client_secret: "pi_secret",
      order: { id: "order-token", stripe_connect_account_id: null },
    },
  },
  can_buyer_sign_up: true,
  offer_codes: [],
};

describe("startClientConfirmOrderCreation", () => {
  beforeEach(() => {
    vi.stubGlobal("Routes", {
      prepare_orders_path: () => "/orders/prepare",
      finalize_order_path: (id: string) => `/orders/${id}/finalize`,
      checkout_return_url: (id: string) => `https://gumroad.test/checkout/returns/${id}`,
    });
    requestMock.mockReset();
    getStripeInstanceMock.mockReset();
    const stripe: Stripe = Object.create(null);
    stripe.confirmPayment = vi.fn().mockResolvedValue({});
    getStripeInstanceMock.mockResolvedValue(stripe);
  });

  it("sends the Payment Element mount currency when preparing a client-confirm checkout", async () => {
    requestMock.mockResolvedValueOnce(jsonResponse({ success: false, error_message: "Try again." }));

    await startClientConfirmOrderCreation(requestData, "ct_123");

    expect(requestMock).toHaveBeenCalledWith(
      expect.objectContaining({
        method: "POST",
        url: "/orders/prepare",
        data: expect.objectContaining({
          confirmation_token: "ct_123",
          payment_element_mount_currency: "usd",
        }),
      }),
    );
  });

  it("throws a non-resubmittable error when finalize returns a failed line item after capture", async () => {
    requestMock.mockResolvedValueOnce(jsonResponse(prepareResponse)).mockResolvedValueOnce(
      jsonResponse({
        success: true,
        line_items: {
          "product-a ": {
            success: false,
            permalink: "product-a",
            error_message: "There is a temporary problem.",
            name: null,
            formatted_price: "$10",
            error_code: null,
            is_tax_mismatch: false,
            card_country: null,
            ip_country: null,
            updated_product: null,
          },
        },
        can_buyer_sign_up: false,
        offer_codes: [],
      }),
    );

    await expect(startClientConfirmOrderCreation(requestData, "ct_123")).rejects.toBeInstanceOf(PaymentConfirmedError);
  });

  it("carries the return-page URL on the error so the buyer can land on a durable outcome", async () => {
    requestMock
      .mockResolvedValueOnce(jsonResponse(prepareResponse))
      .mockResolvedValueOnce(
        jsonResponse({ success: true, line_items: {}, can_buyer_sign_up: false, offer_codes: [] }),
      );

    await expect(startClientConfirmOrderCreation(requestData, "ct_123")).rejects.toMatchObject({
      returnUrl: "https://gumroad.test/checkout/returns/order-token?payment_intent=pi",
    });
  });

  it("carries the return-page URL even when the finalize request itself fails", async () => {
    requestMock.mockResolvedValueOnce(jsonResponse(prepareResponse)).mockRejectedValueOnce(new Error("network down"));

    await expect(startClientConfirmOrderCreation(requestData, "ct_123")).rejects.toMatchObject({
      returnUrl: "https://gumroad.test/checkout/returns/order-token?payment_intent=pi",
    });
  });

  it("throws a non-resubmittable error when finalize returns no line items after capture", async () => {
    requestMock
      .mockResolvedValueOnce(jsonResponse(prepareResponse))
      .mockResolvedValueOnce(
        jsonResponse({ success: true, line_items: {}, can_buyer_sign_up: false, offer_codes: [] }),
      );

    await expect(startClientConfirmOrderCreation(requestData, "ct_123")).rejects.toBeInstanceOf(PaymentConfirmedError);
  });

  it("throws a non-resubmittable error when finalize returns processing after capture", async () => {
    requestMock.mockResolvedValueOnce(jsonResponse(prepareResponse)).mockResolvedValueOnce(
      jsonResponse({
        success: true,
        line_items: { "product-a ": { success: true, processing: true, permalink: "product-a" } },
        can_buyer_sign_up: false,
        offer_codes: [],
      }),
    );

    await expect(startClientConfirmOrderCreation(requestData, "ct_123")).rejects.toBeInstanceOf(PaymentConfirmedError);
  });
});
