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
