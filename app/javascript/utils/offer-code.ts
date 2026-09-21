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

// A code the seller limited to particular options only discounts those options; every other option
// of the product keeps its normal price. Options of a product that share no id with the list are
// unaffected, which is how one code can limit options on one product and cover another entirely.
export const discountAppliesToOption = (
  discount: { option_ids?: string[] | null } | null,
  product: { options: { id: string }[] },
  optionId: string | null,
) => {
  const optionIds = discount?.option_ids;
  if (!optionIds || optionIds.length === 0) return true;
  if (!product.options.some((option) => optionIds.includes(option.id))) return true;

  return optionId !== null && optionIds.includes(optionId);
};
