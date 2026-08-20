import type { Discount } from "$app/parsers/checkout";

type SubscriptionPrice = {
  price: number;
  pre_discount_price: number;
  quantity: number;
  discount: Discount | null;
  is_installment_plan: boolean;
};

const oncePerCartAmount = (discount: Discount | null) =>
  discount?.type === "fixed" && discount.once_per_cart ? (discount.once_per_cart_amount_cents ?? discount.cents) : null;

export const withOncePerCartMinimum = (total: number, discount: Discount | null, minimumPrice: number) =>
  oncePerCartAmount(discount) !== null && total > 0 && total < minimumPrice ? minimumPrice : total;

export const initialSubscriptionUnitPrice = (subscription: SubscriptionPrice) =>
  (subscription.is_installment_plan || oncePerCartAmount(subscription.discount) === null
    ? subscription.price
    : subscription.pre_discount_price) / subscription.quantity;

export const subscriptionPWYWMinimumUnitPrice = (
  undiscountedPrice: number,
  discountedPrice: number,
  discount: Discount | null,
) => (oncePerCartAmount(discount) === null ? discountedPrice : undiscountedPrice);

export const selectedSubscriptionTotal = ({
  unitPrice,
  quantity,
  discount,
  minimumPrice,
}: {
  unitPrice: number;
  quantity: number;
  discount: Discount | null;
  minimumPrice: number;
}) => {
  const total = unitPrice * quantity;
  const amount = oncePerCartAmount(discount);
  if (amount === null) return total;

  const discountedTotal = Math.max(total - amount, 0);
  return withOncePerCartMinimum(discountedTotal, discount, minimumPrice);
};

// Mirrors Subscription::UpdaterService#amount_owed. Overdue charges the new plan
// total with no proration; a same-plan retry still sends the honored total.
export const subscriptionAmountDueToday = ({
  newPriceCents,
  currentPriceCents,
  proratedDiscountCents,
  minimumPriceCents,
  isOverdueForCharge,
  isInFreeTrial,
  isAliveOrPendingCancellation,
  noChangesToCurrentPlan,
}: {
  newPriceCents: number;
  currentPriceCents: number;
  proratedDiscountCents: number;
  minimumPriceCents: number;
  isOverdueForCharge: boolean;
  isInFreeTrial: boolean;
  isAliveOrPendingCancellation: boolean;
  noChangesToCurrentPlan: boolean;
}) => {
  if (isOverdueForCharge || newPriceCents === 0) return newPriceCents;
  if (isAliveOrPendingCancellation && (newPriceCents < currentPriceCents || isInFreeTrial || noChangesToCurrentPlan)) {
    return 0;
  }
  const owed = Math.max(newPriceCents - proratedDiscountCents, 0);
  return owed > 0 ? Math.max(owed, minimumPriceCents) : 0;
};
