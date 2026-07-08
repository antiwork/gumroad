import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { getApplePayRecurringPaymentRequest } from "$app/components/Checkout/applePayRecurringPaymentRequest";
import { Product } from "$app/components/Checkout/payment";

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

describe("getApplePayRecurringPaymentRequest", () => {
  it("returns null for a one-time cart", () => {
    expect(getApplePayRecurringPaymentRequest([product()], MANAGEMENT_URL)).toBeNull();
  });

  it("returns null for a multi-seller one-time cart", () => {
    expect(getApplePayRecurringPaymentRequest([product(), product({ permalink: "b" })], MANAGEMENT_URL)).toBeNull();
  });

  it("declares a monthly recurring request for a single membership", () => {
    const request = getApplePayRecurringPaymentRequest([membership()], MANAGEMENT_URL);
    expect(request).toEqual({
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

  it.each([
    ["quarterly", "month", 3],
    ["biannually", "month", 6],
    ["yearly", "year", 1],
    ["every_two_years", "year", 2],
  ] as const)("maps the %s recurrence onto the sheet interval", (recurrence, unit, count) => {
    const request = getApplePayRecurringPaymentRequest([membership({ recurrence })], MANAGEMENT_URL);
    expect(request?.regularBilling.recurringPaymentIntervalUnit).toBe(unit);
    expect(request?.regularBilling.recurringPaymentIntervalCount).toBe(count);
  });

  it("bills renewals at the renewal price when it differs from today's charge", () => {
    const request = getApplePayRecurringPaymentRequest(
      [membership({ price: 500, renewalPriceCents: 1_000 })],
      MANAGEMENT_URL,
    );
    expect(request?.regularBilling.amount).toBe(1_000);
    expect(request?.billingAgreement).toContain("$10 a month");
  });

  it("bounds the agreement with an end date for a fixed-duration membership", () => {
    // A 12-month membership billed monthly makes 12 payments; the first is charged today, so the
    // agreement ends 11 months out.
    const request = getApplePayRecurringPaymentRequest([membership({ durationInMonths: 12 })], MANAGEMENT_URL);
    const expectedEnd = new Date();
    expectedEnd.setMonth(expectedEnd.getMonth() + 11);
    expect(request?.regularBilling.recurringPaymentEndDate?.getMonth()).toBe(expectedEnd.getMonth());
    expect(request?.regularBilling.recurringPaymentEndDate?.getFullYear()).toBe(expectedEnd.getFullYear());
    expect(request?.billingAgreement).toBe("$10 a month for 12 payments. Manage anytime from your Gumroad library.");
  });

  it("computes billing cycles from the recurrence interval for fixed-duration memberships", () => {
    // 12 months billed quarterly = 4 payments, ending 9 months out.
    const request = getApplePayRecurringPaymentRequest(
      [membership({ recurrence: "quarterly", durationInMonths: 12 })],
      MANAGEMENT_URL,
    );
    const expectedEnd = new Date();
    expectedEnd.setMonth(expectedEnd.getMonth() + 9);
    expect(request?.regularBilling.recurringPaymentEndDate?.getMonth()).toBe(expectedEnd.getMonth());
    expect(request?.billingAgreement).toContain("for 4 payments");
  });

  it("uses the singular 'payment' when the fixed duration fits in a single billing cycle", () => {
    // A 12-month membership billed yearly makes exactly one payment (charged today), so the
    // agreement text must not read "1 payments".
    const request = getApplePayRecurringPaymentRequest(
      [membership({ recurrence: "yearly", durationInMonths: 12 })],
      MANAGEMENT_URL,
    );
    expect(request?.billingAgreement).toBe("$10 a year for 1 payment. Manage anytime from your Gumroad library.");
    // The end date marks the final charge, and with one billing cycle the only charge is today's,
    // so the agreement ends the same day it starts. This is display-only on the payment sheet.
    const today = new Date();
    const endDate = request?.regularBilling.recurringPaymentEndDate;
    expect(endDate?.getFullYear()).toBe(today.getFullYear());
    expect(endDate?.getMonth()).toBe(today.getMonth());
    expect(endDate?.getDate()).toBe(today.getDate());
  });

  it("leaves open-ended memberships without an end date", () => {
    const request = getApplePayRecurringPaymentRequest([membership({ durationInMonths: null })], MANAGEMENT_URL);
    expect(request?.regularBilling.recurringPaymentEndDate).toBeUndefined();
    expect(request?.billingAgreement).toContain("until you cancel");
  });

  it("adds a zero-amount trial line for a free trial membership", () => {
    const request = getApplePayRecurringPaymentRequest(
      [membership({ hasFreeTrial: true, price: 0, renewalPriceCents: 1_000 })],
      MANAGEMENT_URL,
    );
    expect(request?.trialBilling).toEqual({ label: "Free trial", amount: 0 });
    expect(request?.regularBilling.amount).toBe(1_000);
  });

  it("still declares the membership when one-time items share the cart", () => {
    const request = getApplePayRecurringPaymentRequest(
      [membership(), product({ permalink: "one-time" })],
      MANAGEMENT_URL,
    );
    expect(request?.regularBilling.amount).toBe(1_000);
  });

  it("returns null when the cart holds two memberships (Apple models one agreement per payment)", () => {
    expect(
      getApplePayRecurringPaymentRequest([membership(), membership({ permalink: "b" })], MANAGEMENT_URL),
    ).toBeNull();
  });

  it("declares a bounded monthly request for an installment plan", () => {
    const request = getApplePayRecurringPaymentRequest(
      [product({ price: 10_000, payInInstallments: true, installmentPlan: { numberOfInstallments: 4 } })],
      MANAGEMENT_URL,
    );
    expect(request?.regularBilling.amount).toBe(2_500);
    expect(request?.regularBilling.recurringPaymentIntervalUnit).toBe("month");
    expect(request?.regularBilling.recurringPaymentIntervalCount).toBe(1);
    expect(request?.regularBilling.recurringPaymentEndDate).toBeInstanceOf(Date);
    expect(request?.paymentDescription).toBe("Product A (4 monthly installments)");
  });

  it("uses the even base amount for installment renewals when the total doesn't divide evenly", () => {
    // The first installment absorbs the rounding remainder and is charged today; every future
    // (recurring) installment charges the even base amount, which is what the sheet must state.
    const request = getApplePayRecurringPaymentRequest(
      [product({ price: 10_001, payInInstallments: true, installmentPlan: { numberOfInstallments: 4 } })],
      MANAGEMENT_URL,
    );
    expect(request?.regularBilling.amount).toBe(2_500);
  });

  it("returns null for a pay-in-installments item without a plan", () => {
    expect(
      getApplePayRecurringPaymentRequest([product({ payInInstallments: true, installmentPlan: null })], MANAGEMENT_URL),
    ).toBeNull();
  });

  // The subscription manage page mid-plan: some installments were already paid, `price` is
  // today's charge ($0 for a plain payment-method update), and the per-installment amount comes
  // from renewalPriceCents instead of being derived from `price`.
  it("describes only the remaining installments with the renewal amount on the manage page", () => {
    const request = getApplePayRecurringPaymentRequest(
      [
        product({
          price: 0,
          renewalPriceCents: 2_500,
          payInInstallments: true,
          installmentPlan: { numberOfInstallments: 4, remainingInstallments: 2 },
        }),
      ],
      MANAGEMENT_URL,
    );
    expect(request?.regularBilling.amount).toBe(2_500);
    expect(request?.paymentDescription).toBe("Product A (2 monthly installments)");
    expect(request?.billingAgreement).toBe("2 monthly installments of $25.");
  });

  it("returns null for an installment plan with no payments remaining", () => {
    expect(
      getApplePayRecurringPaymentRequest(
        [
          product({
            price: 0,
            renewalPriceCents: 2_500,
            payInInstallments: true,
            installmentPlan: { numberOfInstallments: 4, remainingInstallments: 0 },
          }),
        ],
        MANAGEMENT_URL,
      ),
    ).toBeNull();
  });

  // Declared amounts are pre-tax, matching how the checkout table presents future installments
  // and renewal prices; the server computes each future payment's tax when it is charged.
  it("declares the pre-tax renewal amount", () => {
    const request = getApplePayRecurringPaymentRequest([membership({ price: 1_000 })], MANAGEMENT_URL);
    expect(request?.regularBilling.amount).toBe(1_000);
    expect(request?.billingAgreement).toContain("$10 a month");
  });

  it("declares only the installment item in a mixed cart, without tips", () => {
    // $10 one-time + $200 in 2 installments: the agreement describes only the installment item's
    // future payments ($100, pre-tax). The one-time item and any tip are part of the sheet's
    // one-time total (getChargeTodayPrice), never of the recurring declaration — tips are charged
    // once with the first payment and never re-charged on future installments.
    const request = getApplePayRecurringPaymentRequest(
      [
        product({ permalink: "one-time", price: 1_000 }),
        product({
          permalink: "installments",
          price: 20_000,
          payInInstallments: true,
          installmentPlan: { numberOfInstallments: 2 },
        }),
      ],
      MANAGEMENT_URL,
    );
    expect(request?.regularBilling.amount).toBe(10_000);
    expect(request?.billingAgreement).toContain("2 monthly installments of $100");
  });

  describe("month-boundary end dates", () => {
    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it("clamps a fixed-duration membership end date to the last day of a shorter month", () => {
      // Buying on January 31 with a 2-month monthly membership: the agreement ends one month out.
      // Plain setMonth() would overflow January 31 + 1 month into March 3; the sheet should show
      // the last day of February instead, matching how billing anniversaries clamp.
      vi.setSystemTime(new Date(2026, 0, 31)); // January 31, 2026
      const request = getApplePayRecurringPaymentRequest([membership({ durationInMonths: 2 })], MANAGEMENT_URL);
      const endDate = request?.regularBilling.recurringPaymentEndDate;
      expect(endDate?.getFullYear()).toBe(2026);
      expect(endDate?.getMonth()).toBe(1); // February
      expect(endDate?.getDate()).toBe(28);
    });

    it("clamps an installment plan end date to the last day of a shorter month", () => {
      // 2 installments bought on October 31: the second (last) installment lands one month out,
      // which should clamp to November 30 rather than overflowing into December 1.
      vi.setSystemTime(new Date(2026, 9, 31)); // October 31, 2026
      const request = getApplePayRecurringPaymentRequest(
        [product({ price: 10_000, payInInstallments: true, installmentPlan: { numberOfInstallments: 2 } })],
        MANAGEMENT_URL,
      );
      const endDate = request?.regularBilling.recurringPaymentEndDate;
      expect(endDate?.getFullYear()).toBe(2026);
      expect(endDate?.getMonth()).toBe(10); // November
      expect(endDate?.getDate()).toBe(30);
    });
  });
});
