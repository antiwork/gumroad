import type { Discount } from "$app/parsers/checkout";

type SubscriptionPrice = {
  price: number;
  pre_discount_price: number;
  quantity: number;
  discount: Discount | null;
};

const oncePerCartAmount = (discount: Discount | null) =>
  discount?.type === "fixed" && discount.once_per_cart ? (discount.once_per_cart_amount_cents ?? discount.cents) : null;

export const initialSubscriptionUnitPrice = (subscription: SubscriptionPrice) =>
  (oncePerCartAmount(subscription.discount) === null ? subscription.price : subscription.pre_discount_price) /
  subscription.quantity;

export const selectedSubscriptionTotal = ({
  unitPrice,
  quantity,
  discount,
}: {
  unitPrice: number;
  quantity: number;
  discount: Discount | null;
}) => {
  const total = unitPrice * quantity;
  const amount = oncePerCartAmount(discount);
  return amount === null ? total : Math.max(total - amount, 0);
};
