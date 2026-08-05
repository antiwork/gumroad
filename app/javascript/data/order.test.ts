import type { Stripe } from "@stripe/stripe-js";
import typia from "typia";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  mergeOfferCodes,
  offerCodesForFailedLineItems,
  PaymentConfirmedError,
  startClientConfirmOrderCreation,
  startOrderCreation,
} from "$app/data/order";
import type { ConfirmedPurchaseResponse, StartCartPurchaseRequestPayload } from "$app/data/purchase";
import type { Discount } from "$app/parsers/checkout";
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
const confirmPaymentMock = vi.fn();

const jsonResponse = (body: unknown) => new Response(JSON.stringify(body), { status: 200 });
const fixedDiscount = (cents: number): Extract<Discount, { type: "fixed" }> => ({
  type: "fixed",
  cents,
  product_ids: null,
  expires_at: null,
  minimum_quantity: null,
  duration_in_billing_cycles: null,
  minimum_amount_cents: null,
});
const oncePerCartDiscount = (cents: number, hasUsageLimit = true, id = "offer-code-1"): Discount => ({
  ...fixedDiscount(cents),
  type: "fixed",
  once_per_cart: true,
  once_per_cart_id: id,
  once_per_cart_amount_cents: 100,
  once_per_cart_has_usage_limit: hasUsageLimit,
});

const clientConfirmPaymentMethod = {
  type: "payment-element-client-confirm",
  confirmationTokenId: "ct_123",
  cardCountry: "US",
  walletType: null,
  mountCurrency: "usd",
  methodListToken: null,
  selectedMethodType: "card",
} as const;

const requestData: StartCartPurchaseRequestPayload = {
  paymentMethod: clientConfirmPaymentMethod,
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
  buyerCurrencyQuote: null,
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
      confirmedDuplicatePurchase: false,
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

const confirmedPurchase = (permalink: string): ConfirmedPurchaseResponse => ({
  success: true,
  domain: "gumroad.test",
  protocol: "https",
  name: "Product",
  remaining: null,
  should_show_receipt: true,
  show_view_content_button_on_product_page: true,
  is_recurring_billing: false,
  is_physical: false,
  has_files: true,
  product_id: `product-${permalink}`,
  product_permalink: `https://gumroad.test/l/${permalink}`,
  permalink,
  is_gift_receiver_purchase: false,
  gift_receiver_text: "",
  is_gift_sender_purchase: false,
  gift_sender_text: "",
  content_url: null,
  redirect_token: null,
  url_redirect_external_id: null,
  price: "$10",
  id: `purchase-${permalink}`,
  seller_id: "seller",
  email: "buyer@example.com",
  full_name: "Buyer",
  view_content_button_text: "View content",
  is_following: null,
  has_third_party_analytics: false,
  currency_type: "usd",
  non_formatted_price: 10,
  subscription_has_lapsed: false,
  extra_purchase_notice: null,
  account_by_this_email_exists: false,
  display_product_reviews: false,
  has_shipping_to_show: false,
  shipping_amount: "$0",
  has_sales_tax_to_show: false,
  sales_tax_amount: "$0",
  non_formatted_seller_tax_amount: "0",
  was_tax_excluded_from_price: false,
  sales_tax_label: null,
  has_sales_tax_or_shipping_to_show: false,
  total_price_including_tax_and_shipping: "$10",
  quantity: 1,
  show_quantity: false,
  variants_displayable: "",
  twitter_share_url: "",
  twitter_share_text: "",
  enabled_integrations: { circle: false, discord: false },
  native_type: "digital",
});

describe("mergeOfferCodes", () => {
  it("keeps codes recovered during both order creation and confirmation", () => {
    expect(
      mergeOfferCodes(
        [{ code: "SAVE", products: { first: fixedDiscount(100) } }],
        [{ code: " save ", products: { second: fixedDiscount(0) } }],
      ),
    ).toMatchObject([{ code: "SAVE", products: { first: { cents: 100 }, second: { cents: 0 } } }]);
  });

  it("merges codes that differ only in unicode normalization", () => {
    expect(
      mergeOfferCodes(
        [{ code: "éclair".normalize("NFC"), products: { first: fixedDiscount(100) } }],
        [{ code: "éclair".normalize("NFD"), products: { second: fixedDiscount(0) } }],
      ),
    ).toMatchObject([{ products: { first: { cents: 100 }, second: { cents: 0 } } }]);
  });
});

describe("startOrderCreation", () => {
  it("sends PPP eligibility independently of the winning discount", async () => {
    vi.stubGlobal("Routes", { orders_path: () => "/orders" });
    requestMock.mockReset().mockResolvedValueOnce(jsonResponse({ success: false, error_message: "Try again." }));
    const lineItem = requestData.lineItems.at(0);
    if (!lineItem) throw new Error("Missing test line item");

    await startOrderCreation({ ...requestData, lineItems: [{ ...lineItem, acceptsPppDiscount: true }] });

    expect(requestMock).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          line_items: [expect.objectContaining({ accepts_purchasing_power_parity_discount: true })],
        }),
      }),
    );
  });

  it("preserves active codes when order creation fails before line results", async () => {
    vi.stubGlobal("Routes", { orders_path: () => "/orders" });
    requestMock.mockReset().mockResolvedValueOnce(jsonResponse({ success: false, error_message: "Try again." }));
    const activeOfferCodes = [{ code: "SAVE", products: { "product-a": oncePerCartDiscount(100) } }];

    const result = await startOrderCreation(requestData, activeOfferCodes);

    expect(result.offerCodes).toEqual(activeOfferCodes);
  });

  it("sends failed-line code candidates for server revalidation after SCA", async () => {
    vi.stubGlobal("Routes", {
      orders_path: () => "/orders",
      confirm_order_path: (id: string) => `/orders/${id}/confirm`,
    });
    requestMock.mockReset();
    getStripeInstanceMock.mockReset();
    const stripe = typia.assert<Stripe>({});
    stripe.confirmCardPayment = vi.fn().mockResolvedValue({});
    getStripeInstanceMock.mockResolvedValue(stripe);

    const firstLine = requestData.lineItems.at(0);
    if (!firstLine) throw new Error("Missing test line item");
    const secondLine = { ...firstLine, uid: "product-b ", permalink: "product-b", quantity: 2 };
    const mixedRequestData = { ...requestData, lineItems: [firstLine, secondLine] };
    const activeOfferCodes = [{ code: "SAVE", products: { "product-a": fixedDiscount(100) } }];
    requestMock
      .mockResolvedValueOnce(
        jsonResponse({
          success: true,
          line_items: {
            "product-a ": {
              success: true,
              requires_card_action: true,
              client_secret: "pi_secret",
              order: { id: "order-token", stripe_connect_account_id: null },
            },
            "product-b ": {
              success: false,
              permalink: "product-b",
              error_message: "Invalid variant.",
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
          offer_codes: [{ code: "SAVE", products: { "product-b": oncePerCartDiscount(0) } }],
        }),
      )
      .mockResolvedValueOnce(
        jsonResponse({
          success: true,
          line_items: {
            [firstLine.uid]: confirmedPurchase("product-a"),
            [secondLine.uid]: {
              success: false,
              permalink: "product-b",
              error_message: "Invalid variant.",
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
          offer_codes: [
            {
              code: "save",
              products: { "product-a": fixedDiscount(100), "product-b": oncePerCartDiscount(100) },
            },
          ],
        }),
      );

    const result = await startOrderCreation(mixedRequestData, activeOfferCodes);

    expect(requestMock.mock.calls[1]?.[0]).toMatchObject({
      data: {
        retry_offer_codes: [
          {
            code: "SAVE",
            products: {
              "product-a ": { permalink: "product-a", quantity: 1 },
              "product-b ": { permalink: "product-b", quantity: 2 },
            },
          },
        ],
      },
    });
    expect(result.offerCodes).toEqual([{ code: "save", products: { "product-b": oncePerCartDiscount(100) } }]);
  });

  it("preserves recovered codes when SCA throws before confirmation", async () => {
    vi.stubGlobal("Routes", {
      orders_path: () => "/orders",
      confirm_order_path: (id: string) => `/orders/${id}/confirm`,
      confirm_error_order_path: (id: string) => `/orders/${id}/confirm_error`,
    });
    requestMock.mockReset();
    getStripeInstanceMock.mockReset();
    const stripe = typia.assert<Stripe>({});
    stripe.confirmCardPayment = vi.fn().mockRejectedValue(new Error("Stripe unavailable"));
    getStripeInstanceMock.mockResolvedValue(stripe);

    const lineItem = requestData.lineItems.at(0);
    if (!lineItem) throw new Error("Missing test line item");
    const activeOfferCodes = [{ code: "SAVE", products: { [lineItem.permalink]: oncePerCartDiscount(100) } }];
    requestMock
      .mockResolvedValueOnce(
        jsonResponse({
          success: true,
          line_items: {
            [lineItem.uid]: {
              success: true,
              requires_card_action: true,
              client_secret: "pi_secret",
              order: { id: "order-token", stripe_connect_account_id: null },
            },
          },
          can_buyer_sign_up: false,
          offer_codes: [],
        }),
      )
      .mockResolvedValueOnce(jsonResponse({ success: true, unavailable_once_per_cart_ids: [] }));

    const result = await startOrderCreation(requestData, activeOfferCodes);

    expect(result.offerCodes).toEqual(activeOfferCodes);
  });

  it("does not restore a reserved once-per-cart code when SCA cleanup fails", async () => {
    vi.stubGlobal("Routes", {
      orders_path: () => "/orders",
      confirm_order_path: (id: string) => `/orders/${id}/confirm`,
      confirm_error_order_path: (id: string) => `/orders/${id}/confirm_error`,
    });
    const stripe = typia.assert<Stripe>({});
    stripe.confirmCardPayment = vi.fn().mockRejectedValue(new Error("Stripe unavailable"));
    getStripeInstanceMock.mockResolvedValue(stripe);
    const lineItem = requestData.lineItems.at(0);
    if (!lineItem) throw new Error("Missing test line item");
    const activeOfferCodes = [{ code: "SAVE", products: { [lineItem.permalink]: oncePerCartDiscount(100) } }];
    requestMock
      .mockResolvedValueOnce(
        jsonResponse({
          success: true,
          line_items: {
            [lineItem.uid]: {
              success: true,
              requires_card_action: true,
              client_secret: "pi_secret",
              order: { id: "order-token", stripe_connect_account_id: null },
            },
          },
          can_buyer_sign_up: false,
          offer_codes: [],
        }),
      )
      .mockResolvedValueOnce(jsonResponse({ success: true, unavailable_once_per_cart_ids: ["offer-code-1"] }));

    const result = await startOrderCreation(requestData, activeOfferCodes);

    expect(result.offerCodes).toEqual([]);
  });

  it("drops a legacy code rejected during SCA confirmation", async () => {
    vi.stubGlobal("Routes", {
      orders_path: () => "/orders",
      confirm_order_path: (id: string) => `/orders/${id}/confirm`,
    });
    requestMock.mockReset();
    getStripeInstanceMock.mockReset();
    const stripe = typia.assert<Stripe>({});
    stripe.confirmCardPayment = vi.fn().mockResolvedValue({});
    getStripeInstanceMock.mockResolvedValue(stripe);

    const lineItem = requestData.lineItems.at(0);
    if (!lineItem) throw new Error("Missing test line item");
    const activeOfferCodes = [{ code: "SAVE", products: { [lineItem.permalink]: fixedDiscount(100) } }];
    requestMock
      .mockResolvedValueOnce(
        jsonResponse({
          success: true,
          line_items: {
            [lineItem.uid]: {
              success: true,
              requires_card_action: true,
              client_secret: "pi_secret",
              order: { id: "order-token", stripe_connect_account_id: null },
            },
          },
          can_buyer_sign_up: false,
          offer_codes: [],
        }),
      )
      .mockResolvedValueOnce(
        jsonResponse({
          success: true,
          line_items: {
            purchase: {
              success: false,
              permalink: lineItem.permalink,
              error_message: "The discount is no longer available.",
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

    const result = await startOrderCreation(requestData, activeOfferCodes);

    expect(result.offerCodes).toEqual([]);
  });

  it("keeps both confirmed lines when the cart holds two variants of the same product", async () => {
    vi.stubGlobal("Routes", {
      orders_path: () => "/orders",
      confirm_order_path: (id: string) => `/orders/${id}/confirm`,
    });
    requestMock.mockReset();
    getStripeInstanceMock.mockReset();
    const stripe = typia.assert<Stripe>({});
    stripe.confirmCardPayment = vi.fn().mockResolvedValue({});
    getStripeInstanceMock.mockResolvedValue(stripe);

    const firstLine = requestData.lineItems.at(0);
    if (!firstLine) throw new Error("Missing test line item");
    const secondLine = { ...firstLine, uid: "variant-b " };
    const mixedRequestData = { ...requestData, lineItems: [firstLine, secondLine] };
    requestMock
      .mockResolvedValueOnce(
        jsonResponse({
          success: true,
          line_items: {
            [firstLine.uid]: {
              success: true,
              requires_card_action: true,
              client_secret: "pi_secret",
              order: { id: "order-token", stripe_connect_account_id: null },
            },
            [secondLine.uid]: {
              success: true,
              requires_card_action: true,
              client_secret: "pi_secret",
              order: { id: "order-token", stripe_connect_account_id: null },
            },
          },
          can_buyer_sign_up: false,
          offer_codes: [],
        }),
      )
      .mockResolvedValueOnce(
        jsonResponse({
          success: true,
          line_items: {
            [firstLine.uid]: confirmedPurchase(firstLine.permalink),
            [secondLine.uid]: confirmedPurchase(secondLine.permalink),
          },
          can_buyer_sign_up: false,
          offer_codes: [],
        }),
      );

    const result = await startOrderCreation(mixedRequestData, []);

    // Both lines share a permalink; keying by uid (not permalink) is what keeps them distinct.
    expect(result.lineItems[firstLine.uid]).toMatchObject({ success: true, permalink: firstLine.permalink });
    expect(result.lineItems[secondLine.uid]).toMatchObject({ success: true, permalink: secondLine.permalink });
    expect(result.lineItems[firstLine.uid]).not.toBe(result.lineItems[secondLine.uid]);
  });
});

describe("startClientConfirmOrderCreation", () => {
  beforeEach(() => {
    vi.stubGlobal("Routes", {
      prepare_orders_path: () => "/orders/prepare",
      finalize_order_path: (id: string) => `/orders/${id}/finalize`,
      confirm_error_order_path: (id: string) => `/orders/${id}/confirm_error`,
      checkout_return_url: (id: string) => `https://gumroad.test/checkout/returns/${id}`,
    });
    requestMock.mockReset();
    getStripeInstanceMock.mockReset();
    const stripe = typia.assert<Stripe>({});
    confirmPaymentMock.mockReset().mockResolvedValue({});
    stripe.confirmPayment = confirmPaymentMock;
    getStripeInstanceMock.mockResolvedValue(stripe);
  });

  it("sends the Payment Element mount currency when preparing a client-confirm checkout", async () => {
    requestMock.mockResolvedValueOnce(jsonResponse({ success: false, error_message: "Try again." }));

    await startClientConfirmOrderCreation(requestData, "ct_123", "card");

    expect(requestMock.mock.calls[0]?.[0]).toMatchObject({
      method: "POST",
      url: "/orders/prepare",
      data: {
        confirmation_token: "ct_123",
        payment_element_mount_currency: "usd",
      },
    });
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

    await expect(startClientConfirmOrderCreation(requestData, "ct_123", "card")).rejects.toBeInstanceOf(
      PaymentConfirmedError,
    );
  });

  it("carries the return-page URL on the error so the buyer can land on a durable outcome", async () => {
    requestMock
      .mockResolvedValueOnce(jsonResponse(prepareResponse))
      .mockResolvedValueOnce(
        jsonResponse({ success: true, line_items: {}, can_buyer_sign_up: false, offer_codes: [] }),
      );

    await expect(startClientConfirmOrderCreation(requestData, "ct_123", "card")).rejects.toMatchObject({
      returnUrl: "https://gumroad.test/checkout/returns/order-token?payment_intent=pi",
    });
  });

  it("carries the return-page URL even when the finalize request itself fails", async () => {
    requestMock.mockResolvedValueOnce(jsonResponse(prepareResponse)).mockRejectedValueOnce(new Error("network down"));

    await expect(startClientConfirmOrderCreation(requestData, "ct_123", "card")).rejects.toMatchObject({
      returnUrl: "https://gumroad.test/checkout/returns/order-token?payment_intent=pi",
    });
  });

  it("throws a non-resubmittable error when finalize returns no line items after capture", async () => {
    requestMock
      .mockResolvedValueOnce(jsonResponse(prepareResponse))
      .mockResolvedValueOnce(
        jsonResponse({ success: true, line_items: {}, can_buyer_sign_up: false, offer_codes: [] }),
      );

    await expect(startClientConfirmOrderCreation(requestData, "ct_123", "card")).rejects.toBeInstanceOf(
      PaymentConfirmedError,
    );
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

    await expect(startClientConfirmOrderCreation(requestData, "ct_123", "card")).rejects.toBeInstanceOf(
      PaymentConfirmedError,
    );
  });

  it("keeps active code coverage only for failed lines", () => {
    const firstLine = requestData.lineItems.at(0);
    if (!firstLine) throw new Error("Missing test line item");
    const secondLine = { ...firstLine, uid: "product-b ", permalink: "product-b" };
    const mixedRequestData = { ...requestData, lineItems: [...requestData.lineItems, secondLine] };
    const activeOfferCodes = [
      {
        code: "SAVE",
        products: { "product-a": fixedDiscount(100), "product-b": fixedDiscount(0) },
      },
    ];
    const result = offerCodesForFailedLineItems(
      mixedRequestData,
      { "product-a ": { success: true }, "product-b ": { success: false } },
      activeOfferCodes,
    );

    expect(result).toEqual([{ code: "SAVE", products: { "product-b": fixedDiscount(0) } }]);
  });

  it("does not restore a cart-level code rejected during a no-charge prepare", async () => {
    const firstLine = requestData.lineItems.at(0);
    if (!firstLine) throw new Error("Missing test line item");
    const secondLine = { ...firstLine, uid: "product-b ", permalink: "product-b" };
    const mixedRequestData = { ...requestData, lineItems: [firstLine, secondLine] };
    const activeOfferCodes = [{ code: "SAVE", products: { "product-b": oncePerCartDiscount(0) } }];
    requestMock.mockResolvedValueOnce(
      jsonResponse({
        ...prepareResponse,
        line_items: {
          "product-a ": confirmedPurchase("product-a"),
          "product-b ": {
            success: false,
            permalink: "product-b",
            error_message: "The discount is no longer available.",
            name: null,
            formatted_price: "$10",
            error_code: null,
            is_tax_mismatch: false,
            card_country: null,
            ip_country: null,
            updated_product: null,
          },
        },
        offer_codes: [],
      }),
    );

    const result = await startClientConfirmOrderCreation(mixedRequestData, "ct_123", "card", activeOfferCodes);

    expect(confirmPaymentMock).not.toHaveBeenCalled();
    expect(result.lineItems["product-b "]?.success).toBe(false);
    expect(result.offerCodes).toEqual([]);
  });

  it("does not restore a legacy code rejected during a no-charge prepare", async () => {
    const activeOfferCodes = [{ code: "SAVE", products: { "product-a": fixedDiscount(100) } }];
    requestMock.mockResolvedValueOnce(
      jsonResponse({
        ...prepareResponse,
        line_items: {
          "product-a ": {
            success: false,
            permalink: "product-a",
            error_message: "The discount is no longer available.",
            name: null,
            formatted_price: "$10",
            error_code: null,
            is_tax_mismatch: false,
            card_country: null,
            ip_country: null,
            updated_product: null,
          },
        },
        offer_codes: [],
      }),
    );

    const result = await startClientConfirmOrderCreation(requestData, "ct_123", "card", activeOfferCodes);

    expect(confirmPaymentMock).not.toHaveBeenCalled();
    expect(result.lineItems["product-a "]?.success).toBe(false);
    expect(result.offerCodes).toEqual([]);
  });

  it("drops a legacy code when finalization no longer returns it", async () => {
    const firstLine = requestData.lineItems.at(0);
    if (!firstLine) throw new Error("Missing test line item");
    const secondLine = { ...firstLine, uid: "product-b ", permalink: "product-b" };
    const mixedRequestData = { ...requestData, lineItems: [firstLine, secondLine] };
    requestMock
      .mockResolvedValueOnce(
        jsonResponse({
          ...prepareResponse,
          line_items: {
            ...prepareResponse.line_items,
            "product-b ": {
              success: false,
              permalink: "product-b",
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
          offer_codes: [{ code: "SAVE", products: { "product-b": fixedDiscount(100) } }],
        }),
      )
      .mockResolvedValueOnce(
        jsonResponse({
          success: true,
          line_items: { "product-a ": confirmedPurchase("product-a") },
          can_buyer_sign_up: false,
          offer_codes: [],
        }),
      );

    const result = await startClientConfirmOrderCreation(mixedRequestData, "ct_123", "card");

    expect(requestMock).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        data: {
          retry_offer_codes: [
            {
              code: "SAVE",
              products: { "product-b ": { permalink: "product-b", quantity: 1 } },
            },
          ],
        },
      }),
    );
    expect(result.lineItems["product-b "]?.success).toBe(false);
    expect(result.offerCodes).toEqual([]);
  });

  it("does not restore a legacy code rejected by prepare when another line needs confirmation", async () => {
    const firstLine = requestData.lineItems.at(0);
    if (!firstLine) throw new Error("Missing test line item");
    const secondLine = { ...firstLine, uid: "product-b ", permalink: "product-b" };
    const mixedRequestData = { ...requestData, lineItems: [firstLine, secondLine] };
    const activeOfferCodes = [
      { code: "SAVE", products: { "product-a": fixedDiscount(100), "product-b": fixedDiscount(100) } },
    ];
    requestMock
      .mockResolvedValueOnce(
        jsonResponse({
          ...prepareResponse,
          line_items: {
            ...prepareResponse.line_items,
            "product-b ": {
              success: false,
              permalink: "product-b",
              error_message: "The discount is no longer available.",
              name: null,
              formatted_price: "$10",
              error_code: null,
              is_tax_mismatch: false,
              card_country: null,
              ip_country: null,
              updated_product: null,
            },
          },
          offer_codes: [],
        }),
      )
      .mockResolvedValueOnce(jsonResponse({ success: true }));
    confirmPaymentMock.mockResolvedValueOnce({ error: { message: "Card failed." } });

    const result = await startClientConfirmOrderCreation(mixedRequestData, "ct_123", "card", activeOfferCodes);

    expect(result.offerCodes).toEqual([{ code: "SAVE", products: { "product-a": fixedDiscount(100) } }]);
  });

  it("reports a confirm failure to the server so redirect-method errors are visible in production", async () => {
    const activeOfferCodes = [{ code: "SAVE", products: { "product-a": fixedDiscount(100) } }];
    requestMock
      .mockResolvedValueOnce(jsonResponse(prepareResponse))
      .mockResolvedValueOnce(jsonResponse({ success: true, unavailable_once_per_cart_ids: [] }));
    const stripe = typia.assert<Stripe>({});
    stripe.confirmPayment = vi.fn().mockResolvedValue({
      error: { type: "invalid_request_error", code: "payment_intent_unexpected_state", message: "Bad state." },
    });
    getStripeInstanceMock.mockResolvedValue(stripe);

    const result = await startClientConfirmOrderCreation(requestData, "ct_123", "card", activeOfferCodes);

    const reportRequest = requestMock.mock.calls.find(
      ([options]) => options.url === "/orders/order-token/confirm_error",
    )?.[0];
    expect(reportRequest).toMatchObject({
      method: "POST",
      url: "/orders/order-token/confirm_error",
      data: {
        stage: "confirm",
        stripe_error_type: "invalid_request_error",
        stripe_error_code: "payment_intent_unexpected_state",
        stripe_error_message: "Bad state.",
      },
    });
    // The buyer still sees the failure — reporting must not change the outcome.
    expect(Object.values(result.lineItems).every((lineItem) => !lineItem.success)).toBe(true);
    expect(result.offerCodes).toEqual(activeOfferCodes);
  });

  it("stops waiting for confirm-error cleanup and keeps capped codes unavailable", async () => {
    vi.useFakeTimers();
    try {
      const activeOfferCodes = [{ code: "SAVE", products: { "product-a": oncePerCartDiscount(100) } }];
      requestMock.mockResolvedValueOnce(jsonResponse(prepareResponse)).mockImplementationOnce(
        ({ abortSignal }) =>
          new Promise<Response>((_resolve, reject) => {
            abortSignal?.addEventListener("abort", () => reject(new Error("aborted")));
          }),
      );
      confirmPaymentMock.mockResolvedValueOnce({ error: { message: "Card failed." } });

      const resultPromise = startClientConfirmOrderCreation(requestData, "ct_123", "card", activeOfferCodes);
      await vi.advanceTimersByTimeAsync(5_000);
      const result = await resultPromise;

      expect(result.offerCodes).toEqual([]);
      const reportRequest = requestMock.mock.calls.find(
        ([options]) => options.url === "/orders/order-token/confirm_error",
      )?.[0];
      expect(reportRequest?.abortSignal?.aborted).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it("does not restore a reserved once-per-cart code unless the server releases it", async () => {
    const activeOfferCodes = [{ code: "SAVE", products: { "product-a": oncePerCartDiscount(100) } }];
    requestMock
      .mockResolvedValueOnce(jsonResponse(prepareResponse))
      .mockResolvedValueOnce(jsonResponse({ success: true, unavailable_once_per_cart_ids: ["offer-code-1"] }));
    confirmPaymentMock.mockResolvedValueOnce({ error: { message: "Card failed." } });

    const result = await startClientConfirmOrderCreation(requestData, "ct_123", "card", activeOfferCodes);

    expect(result.offerCodes).toEqual([]);
  });

  it("restores a once-per-cart code after the server releases its reservation", async () => {
    const activeOfferCodes = [{ code: "SAVE", products: { "product-a": oncePerCartDiscount(100) } }];
    requestMock
      .mockResolvedValueOnce(jsonResponse(prepareResponse))
      .mockResolvedValueOnce(jsonResponse({ success: true, unavailable_once_per_cart_ids: [] }));
    confirmPaymentMock.mockResolvedValueOnce({ error: { message: "Card failed." } });

    const result = await startClientConfirmOrderCreation(requestData, "ct_123", "card", activeOfferCodes);

    expect(result.offerCodes).toEqual(activeOfferCodes);
  });

  it("keeps an uncapped once-per-cart code when no reservation can block retry", async () => {
    const activeOfferCodes = [{ code: "SAVE", products: { "product-a": oncePerCartDiscount(100, false) } }];
    requestMock
      .mockResolvedValueOnce(jsonResponse(prepareResponse))
      .mockResolvedValueOnce(jsonResponse({ success: true, unavailable_once_per_cart_ids: ["offer-code-1"] }));
    confirmPaymentMock.mockResolvedValueOnce({ error: { message: "Card failed." } });

    const result = await startClientConfirmOrderCreation(requestData, "ct_123", "card", activeOfferCodes);

    expect(result.offerCodes).toEqual(activeOfferCodes);
  });

  it("keeps a recovered capped code when a different code remains reserved", async () => {
    const firstLine = requestData.lineItems.at(0);
    if (!firstLine) throw new Error("Missing test line item");
    const secondLine = { ...firstLine, uid: "product-b ", permalink: "product-b" };
    const mixedRequestData = { ...requestData, lineItems: [firstLine, secondLine] };
    const reservedCode = {
      code: "RESERVED",
      products: { "product-a": oncePerCartDiscount(100, true, "reserved-code") },
    };
    const recoveredCode = {
      code: "RECOVERED",
      products: { "product-b": oncePerCartDiscount(100, true, "recovered-code") },
    };
    requestMock
      .mockResolvedValueOnce(
        jsonResponse({
          ...prepareResponse,
          line_items: {
            ...prepareResponse.line_items,
            "product-b ": {
              success: false,
              permalink: "product-b",
              error_message: "Try again.",
              name: null,
              formatted_price: "$10",
              error_code: null,
              is_tax_mismatch: false,
              card_country: null,
              ip_country: null,
              updated_product: null,
            },
          },
          offer_codes: [recoveredCode],
        }),
      )
      .mockResolvedValueOnce(
        jsonResponse({
          success: true,
          unavailable_once_per_cart_ids: ["reserved-code"],
        }),
      );
    confirmPaymentMock.mockResolvedValueOnce({ error: { message: "Card failed." } });

    const result = await startClientConfirmOrderCreation(mixedRequestData, "ct_123", "card", [
      reservedCode,
      recoveredCode,
    ]);

    expect(result.offerCodes).toEqual([recoveredCode]);
  });

  it("preserves active codes when a thrown confirmation error releases the attempt", async () => {
    const activeOfferCodes = [{ code: "SAVE", products: { "product-a": fixedDiscount(100) } }];
    requestMock
      .mockResolvedValueOnce(jsonResponse(prepareResponse))
      .mockResolvedValueOnce(jsonResponse({ success: true, unavailable_once_per_cart_ids: [] }));
    confirmPaymentMock.mockRejectedValueOnce(new Error("network down"));

    const result = await startClientConfirmOrderCreation(requestData, "ct_123", "card", activeOfferCodes);

    expect(Object.values(result.lineItems).every((lineItem) => !lineItem.success)).toBe(true);
    expect(result.offerCodes).toEqual(activeOfferCodes);
  });

  it("does not restore a reserved once-per-cart code when thrown-error cleanup fails", async () => {
    const activeOfferCodes = [{ code: "SAVE", products: { "product-a": oncePerCartDiscount(100) } }];
    requestMock
      .mockResolvedValueOnce(jsonResponse(prepareResponse))
      .mockResolvedValueOnce(jsonResponse({ success: true, unavailable_once_per_cart_ids: ["offer-code-1"] }));
    confirmPaymentMock.mockRejectedValueOnce(new Error("network down"));

    const result = await startClientConfirmOrderCreation(requestData, "ct_123", "card", activeOfferCodes);

    expect(result.offerCodes).toEqual([]);
  });

  it("reports the selected Payment Element row, which is the only method signal a decline carries", async () => {
    // A plain decline: Stripe returns no payment_method, so the server can only tell this is a
    // card from the selected row (gumroad-private#1514).
    requestMock
      .mockResolvedValueOnce(jsonResponse(prepareResponse))
      .mockResolvedValueOnce(jsonResponse({ success: true }));
    const stripe = typia.assert<Stripe>({});
    stripe.confirmPayment = vi.fn().mockResolvedValue({
      error: { type: "card_error", code: "card_declined", message: "Your card was declined." },
    });
    getStripeInstanceMock.mockResolvedValue(stripe);

    await startClientConfirmOrderCreation(
      { ...requestData, paymentMethod: { ...clientConfirmPaymentMethod, selectedMethodType: "ideal" } },
      "ct_123",
      "ideal",
    );

    const reportRequest = requestMock.mock.calls.find(
      ([options]) => options.url === "/orders/order-token/confirm_error",
    )?.[0];
    expect(reportRequest).toMatchObject({
      url: "/orders/order-token/confirm_error",
      data: {
        payment_method_type: null,
        selected_payment_method_type: "ideal",
      },
    });
  });
});

// A CAPTCHA refusal happens in a before_action, so it arrives as a whole-order failure with no line
// items of its own. The offer of a challenge retry has to survive being fanned out across the cart
// (gumroad-private#1590).
describe("startOrderCreation", () => {
  beforeEach(() => {
    vi.stubGlobal("Routes", { orders_path: () => "/orders" });
    requestMock.mockReset();
  });

  it("surfaces the challenge-retry offer from a score-only CAPTCHA refusal", async () => {
    requestMock.mockResolvedValueOnce(
      jsonResponse({
        success: false,
        error_message: "Sorry, we could not complete this purchase",
        recaptcha_challenge_available: true,
      }),
    );

    const result = await startOrderCreation(requestData);

    expect(result.recaptchaChallengeAvailable).toBe(true);
    // The refusal is still reported per line item, so a client that ignores the offer behaves as before.
    expect(result.lineItems["product-a "]).toMatchObject({ success: false });
  });

  it("does not offer a retry for an ordinary order failure", async () => {
    requestMock.mockResolvedValueOnce(jsonResponse({ success: false, error_message: "Try again." }));

    const result = await startOrderCreation(requestData);

    expect(result.recaptchaChallengeAvailable).toBe(false);
  });

  it("sends the challenge-fallback marker when resubmitting with a challenge token", async () => {
    requestMock.mockResolvedValueOnce(jsonResponse({ success: false, error_message: "Try again." }));

    await startOrderCreation({
      ...requestData,
      recaptchaResponse: "challenge-token",
      recaptchaChallengeFallback: true,
    });

    expect(requestMock).toHaveBeenCalledWith(
      expect.objectContaining({
        url: "/orders",
        data: expect.objectContaining({
          "g-recaptcha-response": "challenge-token",
          recaptcha_challenge_fallback: true,
        }),
      }),
    );
  });

  it("marks an ordinary submission as not a challenge fallback", async () => {
    requestMock.mockResolvedValueOnce(jsonResponse({ success: false, error_message: "Try again." }));

    await startOrderCreation(requestData);

    expect(requestMock).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ recaptcha_challenge_fallback: false }) }),
    );
  });
});
