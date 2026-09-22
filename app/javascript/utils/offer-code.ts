export type OfferCode = { type: "fixed"; cents: number } | { type: "percent"; percents: number };
export function applyOfferCodeToCents(offerCode: null | OfferCode, amountCents: number): number {
  if (offerCode == null) return amountCents;

  if (offerCode.type === "percent") {
    const ratio = offerCode.percents / 100;
    const discountAmount = Math.round(amountCents * ratio);
    return Math.round(amountCents - discountAmount);
  }
  return Math.round(Math.max(amountCents - offerCode.cents, 0));
}

export const discountAppliesToOption = (
  discount: { option_ids_by_product?: Record<string, string[]> } | null,
  product: { id: string },
  optionId: string | null,
) => {
  const optionIds = discount?.option_ids_by_product?.[product.id];
  return optionIds === undefined || (optionId !== null && optionIds.includes(optionId));
};
