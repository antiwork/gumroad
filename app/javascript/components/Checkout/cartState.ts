import { cast } from "ts-safe-cast";

import { Discount } from "$app/parsers/checkout";
import { AnalyticsData, CustomFieldDescriptor, FreeTrial, ProductNativeType } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { applyOfferCodeToCents } from "$app/utils/offer-code";
import { RecurrenceId } from "$app/utils/recurringPricing";
import { ResponseError, request } from "$app/utils/request";

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
};

export type CartState = {
  items: CartItem[];
  discountCodes: DiscountCode[];
  returnUrl?: string;
  rejectPppDiscount?: boolean;
  email?: string | null;
};

export const convertToUSD = (item: CartItem, price: number) => price / item.product.exchange_rate;
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
export function getDiscountedPrice(cart: CartState, item: CartItem): DiscountedPrice {
  let applicable: DiscountedPrice = {
    discount: null,
    price: item.price * item.quantity,
  };
  for (const discountCode of cart.discountCodes) {
    const discount = discountCode.products[item.product.permalink];
    if (!discount) continue;
    if (
      discount.minimum_amount_cents &&
      cart.items
        .filter(({ product }) => !discount.product_ids || discount.product_ids.includes(product.id))
        .reduce((acc, item) => acc + item.price * item.quantity, 0) < discount.minimum_amount_cents
    )
      continue;
    const discounted = applyOfferCodeToCents(discount, item.price) * item.quantity;
    if (discounted <= applicable.price && hasMetDiscountConditions(discount, item.quantity))
      applicable = { discount: { type: "code", value: discount, code: discountCode.code }, price: discounted };
  }
  if (item.accepted_offer?.discount) {
    const discounted = applyOfferCodeToCents(item.accepted_offer.discount, item.price) * item.quantity;
    if (discounted < applicable.price)
      return { discount: { type: "cross-sell", value: item.accepted_offer.discount }, price: discounted };
  }
  if (item.product.ppp_details && !cart.rejectPppDiscount) {
    const pppDiscountedPrice = computeDiscountedPrice(item.price * item.quantity, null, item.product);
    if (pppDiscountedPrice.value < applicable.price)
      return { discount: { type: "ppp" }, price: pppDiscountedPrice.value };
  }
  return applicable;
}

export function newCartState(): CartState {
  return { items: [], discountCodes: [] };
}

export async function saveCartState(cart: CartState) {
  const response = await request({
    method: "PUT",
    url: Routes.internal_cart_path(),
    accept: "json",
    data: { cart },
  });

  if (!response.ok) {
    const data = cast<{ error?: string }>(await response.json());
    throw new ResponseError(data.error);
  }
}
