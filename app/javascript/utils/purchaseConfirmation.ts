import type { LineItemResult, SuccessfulLineItemResult } from "$app/data/purchase";

export const purchaseConfirmationMessage = ({
  free,
  sellerName,
  email,
}: {
  free: boolean;
  sellerName: string | null;
  email: string;
}) =>
  free
    ? `You signed up${sellerName ? ` with ${sellerName}` : ""} for free. We emailed the details to ${email}.`
    : `Your purchase was successful! We sent a receipt to ${email}.`;

export const freeSignupSummary = (results: { result: LineItemResult }[]) => {
  const successful = results.flatMap(({ result }): SuccessfulLineItemResult[] => (result.success ? [result] : []));
  const sellerIds = new Set(successful.map((result) => result.seller_id));
  return {
    free: successful.length > 0 && successful.every((result) => result.is_free_purchase),
    sellerName: sellerIds.size === 1 ? (successful[0]?.seller_name ?? null) : null,
  };
};
