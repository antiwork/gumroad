export const purchaseConfirmationMessage = ({
  free,
  creatorName,
  email,
}: {
  free: boolean;
  creatorName: string | null;
  email: string;
}) =>
  free
    ? `You're in! Your free signup${creatorName ? ` with ${creatorName}` : ""} is confirmed. We sent a confirmation to ${email}.`
    : `Your purchase was successful! We sent a receipt to ${email}.`;
