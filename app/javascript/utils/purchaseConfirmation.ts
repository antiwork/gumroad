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
    ? `You're in! Your free signup${sellerName ? ` with ${sellerName}` : ""} is confirmed. We sent a confirmation to ${email}.`
    : `Your purchase was successful! We sent a receipt to ${email}.`;
