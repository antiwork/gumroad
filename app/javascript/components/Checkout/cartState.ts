import type { LineItemResult } from "$app/data/purchase";
import { Discount } from "$app/parsers/checkout";
import {
  AnalyticsData,
  BuyerCurrencyDisplay,
  CustomFieldDescriptor,
  FreeTrial,
  ProductNativeType,
} from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { applyOfferCodeToCents } from "$app/utils/offer-code";
import { RecurrenceId } from "$app/utils/recurringPricing";

import {
  Rental,
  Option,
  Recurrences,
  PurchasingPowerParityDetails,
  computeDiscountedPrice,
  hasMetDiscountConditions,
} from "$app/components/Product/ConfigurationSelector";

export type Creator = { name: string; profile_url: string; avatar_url: string; id: string };
export type Product = {
  id: string;
  permalink: string;
  name: string;
  creator: Creator;
  url: string;
  thumbnail_url: string | null;
  currency_code: CurrencyCode;
  price_cents: number;
  buyer_currency_display?: BuyerCurrencyDisplay;
  quantity_remaining: number | null;
  pwyw: { suggested_price_cents: number | null } | null;
  installment_plan: { number_of_installments: number } | null;
  is_preorder: boolean;
  is_tiered_membership: boolean;
  is_legacy_subscription: boolean;
  is_multiseat_license: boolean;
  is_quantity_enabled: boolean;
  free_trial: FreeTrial | null;
  // Either an SKU or a variant from the user's first alive variant_category
  options: (Option & { upsell_offered_variant_id: string | null })[];
  recurrences: Recurrences | null;
  duration_in_months: number | null;
  native_type: ProductNativeType;
  custom_fields: CustomFieldDescriptor[];
  require_shipping: boolean;
  supports_paypal: "native" | "braintree" | null;
  has_offer_codes: boolean;
  has_tipping_enabled: boolean;
  analytics: AnalyticsData;
  exchange_rate: number;
  rental: Rental | null;
  shippable_country_codes: string[];
  ppp_details: PurchasingPowerParityDetails | null;
  upsell: Upsell | null;
  cross_sells: CrossSell[];
  archived: boolean;
  can_gift: boolean;
  bundle_products: {
    product_id: string;
    name: string;
    thumbnail_url: string | null;
    native_type: ProductNativeType;
    url: string;
    quantity: number;
    variant: { id: string; name: string } | null;
    custom_fields: CustomFieldDescriptor[];
  }[];
};

export type Upsell = {
  id: string;
  text: string;
  description: string;
};

export type DiscountCode = { code: string; products: Record<string, Discount>; fromUrl: boolean };

export type CartItem = {
  product: Product;
  price: number;
  quantity: number;
  recurrence: RecurrenceId | null;
  option_id: string | null;
  recommended_by: string | null;
  affiliate_id: string | null;
  rent: boolean;
  url_parameters: Record<string, string>;
  referrer: string;
  recommender_model_name: string | null;
  accepted_offer?: {
    original_product_id?: string | null;
    id: string;
    original_variant_id?: string | null;
    discount?: Discount | null;
  } | null;
  call_start_time: string | null;
  pay_in_installments: boolean;
  force_new_subscription: boolean;
};

export type CrossSell = {
  id: string;
  replace_selected_products: boolean;
  text: string;
  description: string;
  offered_product: ProductToAdd;
  discount: Discount | null;
  ratings: { average: number; count: number } | null;
};

export type ProductToAdd = {
  product: Product;
  recurrence: RecurrenceId | null;
  price: number;
  option_id: string | null;
  rent: boolean;
  quantity: number | null;
  affiliate_id: string | null;
  recommended_by: string | null;
  call_start_time: string | null;
  accepted_offer: { id: string } | null;
  pay_in_installments: boolean;
  force_new_subscription: boolean;
};

export type CartState = {
  items: CartItem[];
  discountCodes: DiscountCode[];
  returnUrl?: string;
  rejectPppDiscount?: boolean;
  email?: string | null;
};

export const convertToUSD = (item: CartItem, price: number) => price / item.product.exchange_rate;

// Copies the server's current exchange rates onto the cart the buyer is already holding,
// matching items by product permalink (the rate is a property of the product's listed
// currency, not of the selected option or quantity).
//
// The rate the checkout converts listed prices with is baked into the page props when the
// page renders, but the server refreshes stored rates every hour. A checkout left open
// across that refresh keeps converting at the old rate, which is how a buyer ends up
// confirming a local-currency total the charge then refuses to honour. The caller supplies
// the server's current rates, read out of the charge-refusal response itself; this merges
// only those rates back in, leaving everything
// the buyer chose (quantity, pay-what-you-want price, option, accepted offers, discounts)
// untouched. Returns the original cart object when no rate actually moved, so an unchanged
// cart doesn't trigger a needless save round-trip.
export const withRefreshedExchangeRates = (cart: CartState, refreshedRates: ReadonlyMap<string, number>): CartState => {
  let changed = false;
  const items = cart.items.map((item) => {
    const rate = refreshedRates.get(item.product.permalink);
    // Keep the rate the cart already has rather than adopting an unusable one: a rate of 0 would
    // make convertToUSD produce Infinity. This is defence for the exported helper rather than a
    // case the checkout reaches — refreshedRatesFromLineItems already drops non-positive rates
    // before building the map, and that is where the server's 0.0 for an unknown currency is
    // actually filtered out.
    if (rate === undefined || !(rate > 0) || rate === item.product.exchange_rate) return item;
    changed = true;
    return { ...item, product: { ...item.product, exchange_rate: rate } };
  });
  return changed ? { ...cart, items } : cart;
};
export const hasFreeTrial = (item: CartItem, isGift: boolean) => item.product.free_trial && !isGift;

export const findCartItem = (cart: CartState, permalink: string, optionId: string | null) =>
  cart.items.find((item) => item.product.permalink === permalink && item.option_id === optionId);

type DiscountedPrice = {
  discount:
    | { type: "code"; value: Discount; code: string }
    | { type: "cross-sell"; value: Discount }
    | { type: "ppp" }
    | null;
  price: number;
};

const hasMetCartDiscountConditions = (cart: CartState, item: CartItem, discount: Discount) =>
  hasMetDiscountConditions(discount, item.quantity) &&
  (!discount.minimum_amount_cents ||
    cart.items
      .filter(
        ({ product }) =>
          (!discount.product_ids || discount.product_ids.includes(product.id)) &&
          !discount.excluded_product_ids?.includes(product.id),
      )
      .reduce((total, cartItem) => total + cartItem.price * cartItem.quantity, 0) >= discount.minimum_amount_cents);

const getNonCodeDiscountedPrice = (cart: CartState, item: CartItem): DiscountedPrice => {
  let applicable: DiscountedPrice = { discount: null, price: item.price * item.quantity };
  if (item.accepted_offer?.discount) {
    const discounted = applyOfferCodeToCents(item.accepted_offer.discount, item.price) * item.quantity;
    if (discounted < applicable.price)
      applicable = { discount: { type: "cross-sell", value: item.accepted_offer.discount }, price: discounted };
  }
  if (item.product.ppp_details && !cart.rejectPppDiscount) {
    const pppDiscountedPrice = computeDiscountedPrice(item.price * item.quantity, null, item.product);
    if (pppDiscountedPrice.value < applicable.price)
      applicable = { discount: { type: "ppp" }, price: pppDiscountedPrice.value };
  }
  return applicable;
};

const isOncePerCartAllocationCandidate = (cart: CartState, item: CartItem, discount: Discount) => {
  if (discount.type !== "fixed" || !hasMetCartDiscountConditions(cart, item, discount)) return false;
  const fullPrice = item.price * item.quantity;
  const discountedPrice = Math.max(fullPrice - (discount.once_per_cart_amount_cents ?? discount.cents), 0);
  return discountedPrice < fullPrice && discountedPrice <= getNonCodeDiscountedPrice(cart, item).price;
};

export function getDiscountedPrice(cart: CartState, item: CartItem, sourceItem: CartItem = item): DiscountedPrice {
  let applicable = getNonCodeDiscountedPrice(cart, item);
  for (const discountCode of cart.discountCodes) {
    const discount = discountCode.products[item.product.permalink];
    if (!discount) continue;
    if (!hasMetCartDiscountConditions(cart, item, discount)) continue;
    const oncePerCart = discount.type === "fixed" && discount.once_per_cart;
    const allocatedItemIndex = oncePerCart
      ? cart.items.findIndex((candidate) => {
          const candidateDiscount = discountCode.products[candidate.product.permalink];
          return (
            candidate.product.creator.id === item.product.creator.id &&
            candidateDiscount?.type === "fixed" &&
            candidateDiscount.once_per_cart &&
            candidateDiscount.once_per_cart_id === discount.once_per_cart_id &&
            isOncePerCartAllocationCandidate(cart, candidate, candidateDiscount)
          );
        })
      : -1;
    const comparableItemIndex = cart.items.indexOf(sourceItem);
    if (oncePerCart && (allocatedItemIndex < 0 || allocatedItemIndex !== comparableItemIndex)) continue;
    const discounted = oncePerCart
      ? Math.max(item.price * item.quantity - (discount.once_per_cart_amount_cents ?? discount.cents), 0)
      : applyOfferCodeToCents(discount, item.price) * item.quantity;
    if (discounted <= applicable.price) {
      const effectiveDiscount = oncePerCart
        ? { ...discount, cents: discount.once_per_cart_amount_cents ?? discount.cents }
        : discount;
      applicable = { discount: { type: "code", value: effectiveDiscount, code: discountCode.code }, price: discounted };
    }
  }
  return applicable;
}

export function newCartState(): CartState {
  return { items: [], discountCodes: [] };
}

export type Result = { item: CartItem; result: LineItemResult };
