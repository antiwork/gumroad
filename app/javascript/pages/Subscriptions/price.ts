import type { Discount } from "$app/parsers/checkout";
import { discountAppliesToOption } from "$app/utils/offer-code";

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

// Plan changes keep the subscription's code without rechecking its spend minimum or the tier's stock, so only
// scope and seat count gate it here. Option previews keep the code's served cents, not the configured amount.
export const subscriptionDiscountForSelection = (
  product: Product,
  discount: Discount | null,
  selection: PriceSelection,
) =>
  discount &&
  discountAppliesToOption(discount, product, selection.optionId) &&
  hasMetDiscountConditions(discount, selection.quantity)
    ? discount
    : null;

export const applySubscriptionSelection = (product: Product, discount: Discount | null, selection: PriceSelection) =>
  applySelection(product, subscriptionDiscountForSelection(product, discount, selection), selection, {
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
