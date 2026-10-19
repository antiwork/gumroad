import type { Discount } from "$app/parsers/checkout";

import {
  applySelection,
  hasMetDiscountConditions,
  type PriceSelection,
  type Product,
} from "$app/components/Product/ConfigurationSelector";

type SubscriptionPrice = {
  price: number;
  pre_discount_price: number;
  quantity: number;
  discount: Discount | null;
  is_installment_plan: boolean;
};

const oncePerCartAmount = (discount: Discount | null) =>
  discount?.type === "fixed" && discount.once_per_cart ? (discount.once_per_cart_amount_cents ?? discount.cents) : null;

// The server resolves each option's plan-change discount. The seat count is picked on this page, so only its
// minimum is checked here, and not against the tier's stock: a subscriber keeps the seats they have.
export const planChangeDiscount = (
  optionDiscounts: Record<string, Discount | null>,
  discount: Discount | null,
  selection: PriceSelection,
) => {
  const selected = selection.optionId === null ? discount : (optionDiscounts[selection.optionId] ?? null);
  return hasMetDiscountConditions(selected, selection.quantity) ? selected : null;
};

export const applyPlanChangeSelection = (
  product: Product,
  optionDiscounts: Record<string, Discount | null>,
  discount: Discount | null,
  selection: PriceSelection,
) =>
  applySelection(product, planChangeDiscount(optionDiscounts, discount, selection), selection, {
    discountConditionsVerified: true,
  });

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
