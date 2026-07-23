import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { getApplePayRecurringPaymentRequest } from "$app/components/Checkout/applePayRecurringPaymentRequest";
import { Product } from "$app/components/Checkout/payment";
import { getPaymentElementApplePayOption } from "$app/components/Checkout/paymentElementApplePayOption";

const MANAGEMENT_URL = "https://gumroad.com/library";

const product = (overrides: Partial<Product> = {}): Product => ({
  permalink: "product-a",
  name: "Product A",
  creator: { id: "seller-a", name: "Seller A", profile_url: "", avatar_url: "" },
  quantity: 1,
  price: 1_000,
  payInInstallments: false,
  requireShipping: false,
  customFields: [],
  bundleProductCustomFields: [],
  supportsPaypal: null,
  testPurchase: false,
  requirePayment: true,
  hasFreeTrial: false,
  hasTippingEnabled: false,
  isPreorder: false,
  canGift: false,
  nativeType: "digital",
  recurrence: null,
  shippableCountryCodes: [],
  ...overrides,
});

const membership = (overrides: Partial<Product> = {}) =>
  product({ nativeType: "membership", recurrence: "monthly", ...overrides });

const bothFlagsOn = { requestApplePayMerchantTokens: true, paymentElementWallets: true };

describe("getPaymentElementApplePayOption", () => {
  // The builder computes the fixed-duration end date from "now"; freeze the clock so two calls in
  // the same test can't land on different milliseconds and fail the payload-parity comparison.
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-10T12:00:00Z"));
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("declares the recurring agreement for a qualifying subscription cart", () => {
    const option = getPaymentElementApplePayOption({
      products: [membership()],
      managementURL: MANAGEMENT_URL,
      ...bothFlagsOn,
    });
    expect(option?.recurringPaymentRequest).toEqual({
      paymentDescription: "Product A",
      managementURL: MANAGEMENT_URL,
      regularBilling: {
        label: "Product A",
        amount: 1_000,
        recurringPaymentIntervalUnit: "month",
        recurringPaymentIntervalCount: 1,
      },
      billingAgreement: "$10 a month until you cancel. Manage or cancel anytime from your Gumroad library.",
    });
  });

  it("produces the exact payload the Payment Request Button surface builds for the same cart", () => {
    // Both wallet surfaces feed the same cart through the same shared builder, so for a given
    // cart Apple sees the identical recurring agreement whichever surface shows the button.
    const products = [membership({ price: 500, renewalPriceCents: 1_000, durationInMonths: 12 })];
    const option = getPaymentElementApplePayOption({ products, managementURL: MANAGEMENT_URL, ...bothFlagsOn });
    expect(option?.recurringPaymentRequest).toEqual(getApplePayRecurringPaymentRequest(products, MANAGEMENT_URL));
  });

  it("declares the trialBilling shape for a free-trial cart (the setup-mode lane)", () => {
    // Free-trial carts mount the element in "setup" mode (nothing is charged today); the
    // declaration still describes the post-trial recurring billing, with a zero-amount trial line
    // telling Apple the first real charge is deferred.
    const option = getPaymentElementApplePayOption({
      products: [membership({ hasFreeTrial: true, price: 0, renewalPriceCents: 1_000 })],
      managementURL: MANAGEMENT_URL,
      ...bothFlagsOn,
    });
    expect(option?.recurringPaymentRequest?.trialBilling).toEqual({ label: "Free trial", amount: 0 });
    expect(option?.recurringPaymentRequest?.regularBilling.amount).toBe(1_000);
  });

  it("returns undefined when the merchant-token rollout flag is off", () => {
    expect(
      getPaymentElementApplePayOption({
        products: [membership()],
        managementURL: MANAGEMENT_URL,
        requestApplePayMerchantTokens: false,
        paymentElementWallets: true,
      }),
    ).toBeUndefined();
  });

  it("returns undefined when the Payment Element wallets flag is off", () => {
    // With payment_element_wallets off the element never shows Apple Pay (the separate Payment
    // Request Button carries the wallet and its own declaration), so the element's options must
    // stay byte-identical to today's.
    expect(
      getPaymentElementApplePayOption({
        products: [membership()],
        managementURL: MANAGEMENT_URL,
        requestApplePayMerchantTokens: true,
        paymentElementWallets: false,
      }),
    ).toBeUndefined();
  });

  it("returns an explicit null declaration for a one-time cart when both flags are on", () => {
    // An explicit null (rather than undefined) matters for option updates: when cart edits make a
    // previously-qualifying cart stop qualifying, element.update() must clear the declaration
    // instead of leaving the stale agreement on the sheet.
    expect(
      getPaymentElementApplePayOption({ products: [product()], managementURL: MANAGEMENT_URL, ...bothFlagsOn }),
    ).toEqual({ recurringPaymentRequest: null });
  });

  it("returns an explicit null declaration for a multi-recurring cart", () => {
    // Apple's sheet models one recurring agreement per payment; two memberships can't be
    // represented truthfully, so the cart keeps a plain one-time request (builder policy).
    expect(
      getPaymentElementApplePayOption({
        products: [membership(), membership({ permalink: "product-b", name: "Product B" })],
        managementURL: MANAGEMENT_URL,
        ...bothFlagsOn,
      }),
    ).toEqual({ recurringPaymentRequest: null });
  });
});
