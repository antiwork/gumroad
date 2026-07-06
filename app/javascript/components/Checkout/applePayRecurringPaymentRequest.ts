import { PaymentRequestOptions } from "@stripe/stripe-js";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { numberOfMonthsInRecurrence, recurrenceLabels } from "$app/utils/recurringPricing";

import { Product } from "$app/components/Checkout/payment";

// Stripe's types define ApplePayRecurringPaymentRequest in an internal module that isn't
// re-exported from the package root, so derive it from the exported PaymentRequestOptions shape.
export type ApplePayRecurringPaymentRequest = NonNullable<
  NonNullable<PaymentRequestOptions["applePay"]>["recurringPaymentRequest"]
>;

// Builds the Apple Pay `recurringPaymentRequest` for a cart, or null when the cart shouldn't
// declare recurring intent.
//
// Why this exists: when the Apple Pay sheet carries a recurring payment request, Apple issues a
// merchant token (MPAN) instead of a device token (DPAN). A DPAN is bound to the card-in-Wallet-
// on-that-device and dies when the buyer wipes, trades in, or upgrades their phone — from then on
// every off-session renewal declines and the subscription churns. An MPAN is bound to the
// buyer↔Gumroad relationship and survives device changes. Nothing about how the charge is
// processed changes; the declaration only affects which kind of token Apple mints. When the
// buyer's card issuer doesn't support merchant tokens, Apple silently falls back to a device
// token, which is exactly today's behavior.
//
// This module is deliberately independent of which Stripe surface shows the wallet button
// (Payment Request Button today, Payment Element / Express Checkout Element later) so the same
// cart policy applies when the wallet surface migrates.
//
// Cart policy: Apple's payment sheet models ONE recurring agreement per payment, so a recurring
// request is only declared when the cart contains exactly one item that bills again in the future
// (a membership, a free trial that converts into one, or an installment plan). Carts with zero
// such items are plain one-time payments; carts with two or more can't be represented truthfully
// on the sheet, so they keep today's one-time request (and a device token) rather than
// misdescribing the purchase.

export const getApplePayRecurringPaymentRequest = (
  products: Product[],
  managementURL: string,
): ApplePayRecurringPaymentRequest | null => {
  const recurringItems = products.filter(
    (item) => item.recurrence !== null || (item.payInInstallments && item.installmentPlan != null),
  );
  if (recurringItems.length !== 1) return null;
  const item = recurringItems[0];
  if (!item) return null;

  if (item.payInInstallments && item.installmentPlan != null) return installmentPlanRequest(item, managementURL);
  return membershipRequest(item, managementURL);
};

const membershipRequest = (item: Product, managementURL: string): ApplePayRecurringPaymentRequest | null => {
  if (item.recurrence === null) return null;

  // The renewal amount can differ from today's charge (e.g. a discount limited to the first
  // billing cycle), so the caller computes it where discount details are available. Falling back
  // to the current price keeps the declaration usable when no separate renewal price is known.
  const renewalAmount = item.renewalPriceCents ?? item.price;
  const months = numberOfMonthsInRecurrence(item.recurrence);
  const interval =
    months % 12 === 0
      ? { recurringPaymentIntervalUnit: "year" as const, recurringPaymentIntervalCount: months / 12 }
      : { recurringPaymentIntervalUnit: "month" as const, recurringPaymentIntervalCount: months };

  // Memberships with a fixed duration stop billing on their own after the configured number of
  // months, so the agreement on the sheet is bounded by an end date rather than described as
  // billing until the buyer cancels.
  const totalBillingCycles = item.durationInMonths != null ? Math.ceil(item.durationInMonths / months) : null;
  let recurringPaymentEndDate: Date | undefined;
  if (totalBillingCycles != null) {
    // The last charge happens one interval before the total duration elapses (the first charge is
    // today), so the agreement ends after (cycles - 1) further intervals.
    recurringPaymentEndDate = new Date();
    recurringPaymentEndDate.setMonth(recurringPaymentEndDate.getMonth() + (totalBillingCycles - 1) * months);
  }

  const formattedRenewal = `${formatPriceCentsWithCurrencySymbol("usd", renewalAmount, { symbolFormat: "short" })} ${
    recurrenceLabels[item.recurrence]
  }`;

  return {
    paymentDescription: item.name,
    managementURL,
    regularBilling: {
      label: item.name,
      amount: renewalAmount,
      ...interval,
      ...(recurringPaymentEndDate ? { recurringPaymentEndDate } : {}),
    },
    // A free trial charges nothing today and bills the regular price after the trial ends. The
    // zero-amount trial line tells Apple (and the buyer, on the sheet) that the first charge is
    // deferred — the case where a durable token matters most, since the token must still be alive
    // when the first real charge happens.
    ...(item.hasFreeTrial ? { trialBilling: { label: "Free trial", amount: 0 } } : {}),
    billingAgreement:
      totalBillingCycles != null
        ? `${formattedRenewal} for ${totalBillingCycles} payments. Manage anytime from your Gumroad library.`
        : `${formattedRenewal} until you cancel. Manage or cancel anytime from your Gumroad library.`,
  };
};

const installmentPlanRequest = (item: Product, managementURL: string): ApplePayRecurringPaymentRequest | null => {
  const numberOfInstallments = item.installmentPlan?.numberOfInstallments;
  if (numberOfInstallments == null || numberOfInstallments < 2) return null;

  // Installments charge monthly until the fixed count is reached. Later installments charge the
  // even base amount (the first installment absorbs the rounding remainder and has already been
  // paid by the time any recurring charge happens), and the end date bounds the agreement.
  const baseInstallmentAmount = Math.floor(item.price / numberOfInstallments);
  const endDate = new Date();
  endDate.setMonth(endDate.getMonth() + numberOfInstallments - 1);

  return {
    paymentDescription: `${item.name} (${numberOfInstallments} monthly installments)`,
    managementURL,
    regularBilling: {
      label: item.name,
      amount: baseInstallmentAmount,
      recurringPaymentIntervalUnit: "month",
      recurringPaymentIntervalCount: 1,
      recurringPaymentEndDate: endDate,
    },
    billingAgreement: `${numberOfInstallments} monthly installments of ${formatPriceCentsWithCurrencySymbol(
      "usd",
      baseInstallmentAmount,
      { symbolFormat: "short" },
    )}.`,
  };
};
