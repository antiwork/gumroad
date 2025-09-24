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

export function sanitizeOfferCode(value: string): string {
  const upperValue = value.toUpperCase();
  // Only allow letters, numbers, dashes, and underscores
  return upperValue.replace(/[^A-Z0-9\-_]/gu, "");
}
