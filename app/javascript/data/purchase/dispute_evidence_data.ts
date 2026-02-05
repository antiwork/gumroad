export const cancellationRebuttalOptions = {
  customer_did_not_request: "The customer did not request cancellation",
  customer_reactivated: "The customer reactivated their subscription",
  customer_agreed_to_keep: "The customer agreed to keep the subscription",
  other: "Other",
};
export type CancellationRebuttalOption = keyof typeof cancellationRebuttalOptions;

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

export const disputeReasons = {
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
