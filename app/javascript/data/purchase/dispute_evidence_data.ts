// Keys first as a const tuple so the union derives from them: Object.keys widens to string[],
// and `assertionStyle: "never"` rules out casting it back.
export const cancellationRebuttalOptionKeys = [
  "customer_did_not_request",
  "customer_reactivated",
  "customer_agreed_to_keep",
  "other",
] as const;
export type CancellationRebuttalOption = (typeof cancellationRebuttalOptionKeys)[number];

export const cancellationRebuttalOptions: Record<CancellationRebuttalOption, string> = {
  customer_did_not_request: "The customer did not request cancellation",
  customer_reactivated: "The customer reactivated their subscription",
  customer_agreed_to_keep: "The customer agreed to keep the subscription",
  other: "Other",
};

export const reasonForWinningOptions = {
  cardholder_withdrew_dispute: "The cardholder withdrew the dispute",
  cardholder_refunded: "The cardholder was refunded",
  transaction_non_refundable: "The transaction was non-refundable",
  refund_request_too_late: "The refund or cancellation request was made after the date allowed by your terms",
  product_as_advertised: "The product received was as advertised",
  cardholder_received_credit: "The cardholder received a credit or voucher",
  cardholder_received_product: "The cardholder received the product or service",
  purchase_made_by_cardholder: "The purchase was made by the rightful cardholder",
  purchase_is_unique: "The purchase is unique",
  product_cancelled_gvnt:
    "The product, service, event or booking was cancelled or delayed due to a government order (COVID-19)",
  other: "Other",
};
export type ReasonForWinningOption = keyof typeof reasonForWinningOptions;

// Mirrors Stripe's `reason` enum on the dispute object. A reason that is not a key here — a code
// added to Stripe after this map was written, or a network-specific one — has no entry, so callers
// must resolve it through disputeReasonEntry instead of indexing disputeReasons directly.
export const disputeReasons = {
  bank_cannot_process: {
    message: "The cardholder's bank cannot process the charge.",
    reasonsForWinning: ["cardholder_withdrew_dispute", "cardholder_refunded", "purchase_made_by_cardholder", "other"],
  },
  check_returned: {
    message: "The cardholder's check was returned.",
    reasonsForWinning: ["cardholder_withdrew_dispute", "cardholder_refunded", "purchase_made_by_cardholder", "other"],
  },
  credit_not_processed: {
    message: "The cardholder claims you have not yet refunded their return or cancellation.",
    refusalRequiresExplanation: true,
    reasonsForWinning: [
      "cardholder_withdrew_dispute",
      "cardholder_refunded",
      "transaction_non_refundable",
      "refund_request_too_late",
      "cardholder_received_credit",
      "product_cancelled_gvnt",
      "other",
    ],
  },
  customer_initiated: {
    message: "The cardholder initiated the dispute with their bank.",
    reasonsForWinning: [
      "cardholder_withdrew_dispute",
      "cardholder_refunded",
      "product_as_advertised",
      "cardholder_received_product",
      "purchase_made_by_cardholder",
      "other",
    ],
  },
  debit_not_authorized: {
    message: "The cardholder's bank claims the debit was not authorized by the account holder.",
    reasonsForWinning: ["cardholder_withdrew_dispute", "cardholder_refunded", "purchase_made_by_cardholder", "other"],
  },
  duplicate: {
    message: "The cardholder claims they were charged multiple times for the same product or service.",
    reasonsForWinning: ["cardholder_withdrew_dispute", "cardholder_refunded", "purchase_is_unique", "other"],
  },
  fraudulent: {
    message: "The cardholder claims they did not authorize the purchase.",
    reasonsForWinning: ["cardholder_withdrew_dispute", "cardholder_refunded", "purchase_made_by_cardholder", "other"],
  },
  general: {
    message:
      "This is an uncategorized inquiry for which we have no details. Contact your customer to understand why they filed this dispute.",
    reasonsForWinning: [
      "cardholder_withdrew_dispute",
      "cardholder_refunded",
      "transaction_non_refundable",
      "refund_request_too_late",
      "product_as_advertised",
      "cardholder_received_credit",
      "cardholder_received_product",
      "purchase_made_by_cardholder",
      "purchase_is_unique",
      "product_cancelled_gvnt",
      "other",
    ],
    refusalRequiresExplanation: true,
  },
  incorrect_account_details: {
    message: "The cardholder's bank claims the account details provided were incorrect.",
    reasonsForWinning: ["cardholder_withdrew_dispute", "cardholder_refunded", "purchase_made_by_cardholder", "other"],
  },
  insufficient_funds: {
    message: "The cardholder's bank claims the account had insufficient funds.",
    reasonsForWinning: ["cardholder_withdrew_dispute", "cardholder_refunded", "purchase_made_by_cardholder", "other"],
  },
  noncompliant: {
    message: "The cardholder's bank claims the charge was noncompliant.",
    reasonsForWinning: [
      "cardholder_withdrew_dispute",
      "cardholder_refunded",
      "product_as_advertised",
      "cardholder_received_product",
      "other",
    ],
  },
  product_not_received: {
    message: "The cardholder claims they did not receive the product or service.",
    reasonsForWinning: [
      "cardholder_withdrew_dispute",
      "cardholder_refunded",
      "cardholder_received_product",
      "product_cancelled_gvnt",
      "other",
    ],
  },
  product_unacceptable: {
    message: "The cardholder claims the product or service was defective, damaged, or not as described.",
    reasonsForWinning: [
      "cardholder_withdrew_dispute",
      "cardholder_refunded",
      "transaction_non_refundable",
      "refund_request_too_late",
      "product_as_advertised",
      "cardholder_received_credit",
      "cardholder_received_product",
      "other",
    ],
  },
  subscription_canceled: {
    message: "Contact your customer to understand why they filed this dispute.",
    reasonsForWinning: [
      "cardholder_withdrew_dispute",
      "cardholder_refunded",
      "transaction_non_refundable",
      "cardholder_received_product",
      "other",
    ],
  },
  unrecognized: {
    message: "The cardholder doesn't recognize the payment appearing on their account statement.",
    reasonsForWinning: [
      "cardholder_withdrew_dispute",
      "cardholder_refunded",
      "transaction_non_refundable",
      "refund_request_too_late",
      "cardholder_received_credit",
      "cardholder_received_product",
      "purchase_made_by_cardholder",
      "product_cancelled_gvnt",
      "other",
    ],
  },
} satisfies Record<
  string,
  { message: string; refusalRequiresExplanation?: true; reasonsForWinning: ReasonForWinningOption[] }
>;
export type DisputeReason = keyof typeof disputeReasons;
export type DisputeReasonEntry = (typeof disputeReasons)[DisputeReason];

// Widened view so a key the map does not contain resolves to undefined instead of being rejected at
// the type level. The presenter forwards Stripe's raw `reason` string, which can be a value this map
// does not know; resolving through here falls back to `general` so an unrecognized reason can never
// blank the evidence form while the seller still has a window to submit their side.
const disputeReasonsByKey: Record<string, DisputeReasonEntry | undefined> = disputeReasons;

export const disputeReasonEntry = (reason: string): DisputeReasonEntry =>
  disputeReasonsByKey[reason] ?? disputeReasons.general;
