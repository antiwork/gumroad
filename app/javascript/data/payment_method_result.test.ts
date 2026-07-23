import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  confirmCardIfNeeded,
  prepareFutureCharges,
  preparePaymentElementPaymentMethodData,
} from "$app/data/card_payment_method_data";
import {
  type CardPaymentMethodParams,
  type ReusableCardPaymentMethodParams,
  type StripeErrorParams,
} from "$app/data/payment_method_params";
import {
  getPaymentMethodResult,
  getReusablePaymentMethodResult,
  type NewPaymentElementSelectedPaymentMethod,
} from "$app/data/payment_method_result";

import { type Product } from "$app/components/Checkout/payment";

vi.mock("$app/data/card_payment_method_data", () => ({
  confirmCardIfNeeded: vi.fn(async (data) => data.cardParams),
  prepareCardPaymentMethodData: vi.fn(),
  prepareFutureCharges: vi.fn(),
  preparePaymentElementPaymentMethodData: vi.fn(),
}));

const cardParams: CardPaymentMethodParams = {
  status: "success",
  type: "card",
  reusable: false,
  stripe_payment_method_id: "pm_123",
  card_country: "US",
  card_country_source: "stripe",
};

const reusableCardParams: ReusableCardPaymentMethodParams = {
  ...cardParams,
  reusable: true,
  stripe_customer_id: "cus_123",
  stripe_setup_intent_id: "seti_123",
};

const stripeErrorParams: StripeErrorParams = {
  status: "error",
  stripe_error: {
    type: "validation_error",
    message: "Card details are incomplete.",
  },
};

const product: Product = {
  permalink: "membership",
  name: "Membership",
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
  nativeType: "membership",
  recurrence: "monthly",
  shippableCountryCodes: [],
};

const selectedPaymentMethod = (): NewPaymentElementSelectedPaymentMethod => ({
  type: "payment-element",
  stripe: Object.create(null),
  elements: Object.create(null),
  email: "buyer@example.com",
  fullName: "Buyer Name",
  keepOnFile: true,
  zipCode: "10001",
  country: "US",
  state: "NY",
  city: "New York",
  address: "123 Main St",
  billingDetailsCollection: "form",
});

describe("getPaymentMethodResult", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("forwards the wallet click-time submit promise into Payment Element tokenization", async () => {
    vi.mocked(preparePaymentElementPaymentMethodData).mockResolvedValue(cardParams);
    const pendingSubmit = Promise.resolve({});

    await getPaymentMethodResult({ ...selectedPaymentMethod(), billingDetailsCollection: "element", pendingSubmit });

    expect(preparePaymentElementPaymentMethodData).toHaveBeenCalledWith(
      expect.objectContaining({ billingDetailsCollection: "element", pendingSubmit }),
    );
  });

  it("passes a null pendingSubmit for non-wallet Payment Element submissions", async () => {
    vi.mocked(preparePaymentElementPaymentMethodData).mockResolvedValue(cardParams);

    await getPaymentMethodResult(selectedPaymentMethod());

    expect(preparePaymentElementPaymentMethodData).toHaveBeenCalledWith(
      expect.objectContaining({ pendingSubmit: null }),
    );
  });
});

describe("getReusablePaymentMethodResult", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("routes Payment Element cards through the reusable card setup flow", async () => {
    vi.mocked(preparePaymentElementPaymentMethodData).mockResolvedValue(cardParams);
    vi.mocked(prepareFutureCharges).mockResolvedValue({
      cardParams: reusableCardParams,
      requiresCardSetup: false,
    });

    const paymentMethod = selectedPaymentMethod();

    await expect(getReusablePaymentMethodResult(paymentMethod, { products: [product] })).resolves.toEqual({
      type: "new",
      cardParamsResult: {
        type: "cc",
        cardParams: reusableCardParams,
        keepOnFile: true,
        zipCode: "10001",
      },
    });
    expect(preparePaymentElementPaymentMethodData).toHaveBeenCalledWith({
      stripe: paymentMethod.stripe,
      elements: paymentMethod.elements,
      email: "buyer@example.com",
      fullName: "Buyer Name",
      zipCode: "10001",
      country: "US",
      state: "NY",
      city: "New York",
      address: "123 Main St",
      billingDetailsCollection: "form",
      pendingSubmit: null,
    });
    expect(prepareFutureCharges).toHaveBeenCalledWith({ products: [product], cardParams });
    expect(confirmCardIfNeeded).toHaveBeenCalledWith({ cardParams: reusableCardParams, requiresCardSetup: false });
  });

  it("passes required card setup responses to the card confirmation helper", async () => {
    vi.mocked(preparePaymentElementPaymentMethodData).mockResolvedValue(cardParams);
    vi.mocked(prepareFutureCharges).mockResolvedValue({
      cardParams: reusableCardParams,
      requiresCardSetup: { client_secret: "seti_secret_123" },
    });

    await getReusablePaymentMethodResult(selectedPaymentMethod(), { products: [product] });

    expect(confirmCardIfNeeded).toHaveBeenCalledWith({
      cardParams: reusableCardParams,
      requiresCardSetup: { client_secret: "seti_secret_123" },
    });
  });

  it("does not prepare future charges when Payment Element card creation returns an error", async () => {
    vi.mocked(preparePaymentElementPaymentMethodData).mockResolvedValue(stripeErrorParams);

    await expect(getReusablePaymentMethodResult(selectedPaymentMethod(), { products: [product] })).resolves.toEqual({
      type: "new",
      cardParamsResult: {
        type: "error",
        cardParams: stripeErrorParams,
      },
    });
    expect(prepareFutureCharges).not.toHaveBeenCalled();
    expect(confirmCardIfNeeded).not.toHaveBeenCalled();
  });
});
