import { describe, expect, it } from "vitest";

import type { Discount } from "$app/parsers/checkout";

import { getDiscountedPrice, getOncePerCartDiscountRank } from "$app/components/Checkout/cartState";
import type { CartItem, CartState, Product } from "$app/components/Checkout/cartState";

const product: Product = {
  id: "product-id",
  permalink: "product",
  name: "Product",
  creator: { id: "seller-id", name: "Seller", profile_url: "#", avatar_url: "" },
  url: "#",
  thumbnail_url: null,
  currency_code: "usd",
  price_cents: 1_000,
  quantity_remaining: null,
  pwyw: null,
  installment_plan: null,
  is_preorder: false,
  is_tiered_membership: false,
  is_legacy_subscription: false,
  is_multiseat_license: false,
  is_quantity_enabled: false,
  free_trial: null,
  options: [],
  recurrences: null,
  duration_in_months: null,
  native_type: "digital",
  custom_fields: [],
  require_shipping: false,
  supports_paypal: null,
  has_offer_codes: true,
  has_tipping_enabled: false,
  analytics: { google_analytics_id: null, facebook_pixel_id: null, tiktok_pixel_id: null, free_sales: false },
  exchange_rate: 1,
  rental: null,
  shippable_country_codes: [],
  ppp_details: null,
  upsell: null,
  cross_sells: [],
  archived: false,
  can_gift: false,
  bundle_products: [],
};

const item: CartItem = {
  price: 1_000,
  quantity: 2,
  product,
  recurrence: null,
  option_id: null,
  recommended_by: null,
  affiliate_id: null,
  rent: false,
  url_parameters: {},
  referrer: "",
  recommender_model_name: null,
  call_start_time: null,
  pay_in_installments: false,
  force_new_subscription: false,
};

const discountConditions = {
  product_ids: null,
  expires_at: null,
  minimum_quantity: null,
  duration_in_billing_cycles: null,
  minimum_amount_cents: null,
};

const cartWith = (discount: Discount): CartState => ({
  items: [item],
  discountCodes: [{ code: "SAVE", products: { product: discount }, fromUrl: false }],
});

describe("getDiscountedPrice", () => {
  it("reports the order used to allocate a cart discount", () => {
    const firstItem = { ...item, price: 500, quantity: 1 };
    const secondProduct = { ...product, id: "second-product-id", permalink: "second-product" };
    const secondItem = { ...item, product: secondProduct, price: 2_000, quantity: 1 };
    const oncePerCartDiscount = { type: "fixed" as const, cents: 1_500, once_per_cart: true, ...discountConditions };
    const cart: CartState = {
      items: [firstItem, secondItem],
      discountCodes: [
        {
          code: "SAVE",
          products: { product: oncePerCartDiscount, "second-product": oncePerCartDiscount },
          fromUrl: false,
        },
      ],
    };

    expect(getOncePerCartDiscountRank(cart, firstItem)).toBe(0);
    expect(getOncePerCartDiscountRank(cart, secondItem)).toBe(1);
    expect(getDiscountedPrice(cart, firstItem).price).toBe(0);
    expect(getDiscountedPrice(cart, secondItem).price).toBe(1_000);
  });

  it("deducts an order-level fixed discount once across the line quantity", () => {
    const cart = cartWith({ type: "fixed", cents: 100, once_per_cart: true, ...discountConditions });

    expect(getDiscountedPrice(cart, item).price).toBe(1_900);
  });

  it("deducts the cart discount from a multi-quantity PWYW total", () => {
    const pwywItem = { ...item, product: { ...product, pwyw: { suggested_price_cents: null } } };
    const cart = cartWith({ type: "fixed", cents: 100, once_per_cart: true, ...discountConditions });
    cart.items = [pwywItem];

    const result = getDiscountedPrice(cart, pwywItem);

    expect(result.price).toBe(1_900);
    expect(result.discount?.type).toBe("code");
  });

  it("keeps legacy fixed discounts applying once per item", () => {
    const cart = cartWith({ type: "fixed", cents: 100, ...discountConditions });

    expect(getDiscountedPrice(cart, item).price).toBe(1_800);
  });

  it("allocates the discount to only the first line when products repeat", () => {
    const secondItem = { ...item };
    const cart = cartWith({ type: "fixed", cents: 100, once_per_cart: true, ...discountConditions });
    cart.items = [item, secondItem];

    expect(getDiscountedPrice(cart, item).price).toBe(1_900);
    expect(getDiscountedPrice(cart, secondItem).price).toBe(2_000);
  });

  it("allocates matching codes once for each seller", () => {
    const otherProduct = {
      ...product,
      id: "other-product-id",
      permalink: "other-product",
      creator: { ...product.creator, id: "other-seller-id" },
    };
    const otherItem = { ...item, product: otherProduct };
    const discount = {
      type: "fixed" as const,
      cents: 100,
      once_per_cart: true,
      once_per_cart_amount_cents: 100,
      ...discountConditions,
    };
    const cart: CartState = {
      items: [item, otherItem],
      discountCodes: [
        {
          code: "SAVE",
          products: { [product.permalink]: discount, [otherProduct.permalink]: discount },
          fromUrl: false,
        },
      ],
    };

    expect(getDiscountedPrice(cart, item).price).toBe(1_900);
    expect(getDiscountedPrice(cart, otherItem).price).toBe(1_900);
  });

  it("allocates separate product-scoped codes with the same text", () => {
    const secondProduct = { ...product, id: "second-id", permalink: "second" };
    const secondItem = { ...item, product: secondProduct };
    const firstDiscount = {
      type: "fixed" as const,
      cents: 100,
      once_per_cart: true,
      once_per_cart_id: "first-code",
      once_per_cart_amount_cents: 100,
      ...discountConditions,
    };
    const secondDiscount = { ...firstDiscount, once_per_cart_id: "second-code" };
    const cart: CartState = {
      items: [item, secondItem],
      discountCodes: [
        {
          code: "SAVE",
          products: { [product.permalink]: firstDiscount, [secondProduct.permalink]: secondDiscount },
          fromUrl: false,
        },
      ],
    };

    expect(getDiscountedPrice(cart, item).price).toBe(1_900);
    expect(getDiscountedPrice(cart, secondItem).price).toBe(1_900);
  });

  it("moves the configured amount when the original winning line is removed", () => {
    const remainingProduct = { ...product, id: "remaining-id", permalink: "remaining" };
    const remainingItem = { ...item, product: remainingProduct };
    const cart: CartState = {
      items: [remainingItem],
      discountCodes: [
        {
          code: "SAVE",
          products: {
            remaining: {
              type: "fixed",
              cents: 0,
              once_per_cart: true,
              once_per_cart_amount_cents: 100,
              ...discountConditions,
            },
          },
          fromUrl: false,
        },
      ],
    };

    const result = getDiscountedPrice(cart, remainingItem);
    const effectiveDiscount = result.discount?.type === "code" ? result.discount.value : null;

    expect(result.price).toBe(1_900);
    expect(effectiveDiscount?.type === "fixed" ? effectiveDiscount.cents : null).toBe(100);
  });

  it("carries a cart-level discount across lines when the first line cannot absorb it", () => {
    const secondProduct = { ...product, id: "second-id", permalink: "second" };
    const firstItem = { ...item, price: 1_000, quantity: 1 };
    const secondItem = { ...item, price: 1_000, quantity: 1, product: secondProduct };
    const discount = {
      type: "fixed" as const,
      cents: 1_500,
      once_per_cart: true,
      once_per_cart_amount_cents: 1_500,
      ...discountConditions,
    };
    const cart: CartState = {
      items: [firstItem, secondItem],
      discountCodes: [{ code: "SAVE", products: { product: discount, second: discount }, fromUrl: false }],
    };

    const firstResult = getDiscountedPrice(cart, firstItem);
    const secondResult = getDiscountedPrice(cart, secondItem);

    expect(firstResult.price).toBe(0);
    expect(secondResult.price).toBe(500);
    expect(
      firstResult.discount?.type === "code" && firstResult.discount.value.type === "fixed"
        ? firstResult.discount.value.cents
        : null,
    ).toBe(1_000);
    expect(
      secondResult.discount?.type === "code" && secondResult.discount.value.type === "fixed"
        ? secondResult.discount.value.cents
        : null,
    ).toBe(500);
  });

  it("does not submit the code from a covered line that received no allocation", () => {
    const secondProduct = { ...product, id: "second-id", permalink: "second" };
    const secondItem = { ...item, product: secondProduct };
    const cart: CartState = {
      items: [item, secondItem],
      discountCodes: [
        {
          code: "SAVE",
          products: {
            product: {
              type: "fixed",
              cents: 100,
              once_per_cart: true,
              once_per_cart_amount_cents: 100,
              ...discountConditions,
            },
            second: {
              type: "fixed",
              cents: 0,
              once_per_cart: true,
              once_per_cart_amount_cents: 100,
              ...discountConditions,
            },
          },
          fromUrl: false,
        },
      ],
    };

    expect(getDiscountedPrice(cart, secondItem)).toEqual({ discount: null, price: 2_000 });
  });

  it("moves the allocation when the first covered line no longer meets the minimum quantity", () => {
    const secondProduct = { ...product, id: "second-id", permalink: "second" };
    const firstItem = { ...item, quantity: 1 };
    const secondItem = { ...item, quantity: 2, product: secondProduct };
    const discount = {
      type: "fixed" as const,
      cents: 100,
      once_per_cart: true,
      once_per_cart_amount_cents: 100,
      ...discountConditions,
      minimum_quantity: 2,
    };
    const cart: CartState = {
      items: [firstItem, secondItem],
      discountCodes: [
        {
          code: "SAVE",
          products: { product: discount, second: { ...discount, cents: 0 } },
          fromUrl: false,
        },
      ],
    };

    expect(getDiscountedPrice(cart, firstItem)).toEqual({ discount: null, price: 1_000 });
    expect(getDiscountedPrice(cart, secondItem).price).toBe(1_900);
  });

  it("moves the allocation when a cross-sell discount wins on the first covered line", () => {
    const secondProduct = { ...product, id: "second-id", permalink: "second" };
    const firstItem = {
      ...item,
      accepted_offer: {
        id: "upsell",
        discount: { type: "fixed" as const, cents: 200, ...discountConditions },
      },
    };
    const secondItem = { ...item, product: secondProduct };
    const discount = {
      type: "fixed" as const,
      cents: 100,
      once_per_cart: true,
      once_per_cart_amount_cents: 100,
      ...discountConditions,
    };
    const cart: CartState = {
      items: [firstItem, secondItem],
      discountCodes: [{ code: "SAVE", products: { product: discount, second: discount }, fromUrl: false }],
    };

    expect(getDiscountedPrice(cart, firstItem).price).toBe(1_600);
    expect(getDiscountedPrice(cart, secondItem).price).toBe(1_900);
  });

  it("moves the allocation when PPP wins on the first covered line", () => {
    const firstProduct = { ...product, ppp_details: { country: "US", factor: 0.5, minimum_price: 0 } };
    const secondProduct = { ...product, id: "second-id", permalink: "second" };
    const firstItem = { ...item, product: firstProduct };
    const secondItem = { ...item, product: secondProduct };
    const discount = {
      type: "fixed" as const,
      cents: 100,
      once_per_cart: true,
      once_per_cart_amount_cents: 100,
      ...discountConditions,
    };
    const cart: CartState = {
      items: [firstItem, secondItem],
      discountCodes: [{ code: "SAVE", products: { product: discount, second: discount }, fromUrl: false }],
    };

    expect(getDiscountedPrice(cart, firstItem).price).toBe(1_000);
    expect(getDiscountedPrice(cart, secondItem).price).toBe(1_900);
  });

  it("allocates the cart discount where it saves more than PPP", () => {
    const firstProduct = { ...product, ppp_details: { country: "US", factor: 0.8, minimum_price: 0 } };
    const secondProduct = { ...product, id: "second-id", permalink: "second" };
    const firstItem = { ...item, price: 1_000, quantity: 1, product: firstProduct };
    const secondItem = { ...item, price: 1_000, quantity: 1, product: secondProduct };
    const discount = {
      type: "fixed" as const,
      cents: 500,
      once_per_cart: true,
      once_per_cart_amount_cents: 500,
      ...discountConditions,
    };
    const cart: CartState = {
      items: [firstItem, secondItem],
      discountCodes: [{ code: "SAVE", products: { product: discount, second: discount }, fromUrl: false }],
    };

    expect(getDiscountedPrice(cart, firstItem)).toEqual({ discount: { type: "ppp" }, price: 800 });
    expect(getDiscountedPrice(cart, secondItem).price).toBe(500);
  });

  it("moves the allocation when another code wins on the first covered line", () => {
    const secondProduct = { ...product, id: "second-id", permalink: "second" };
    const firstItem = { ...item, quantity: 1 };
    const secondItem = { ...item, quantity: 1, product: secondProduct };
    const cartDiscount = {
      type: "fixed" as const,
      cents: 500,
      once_per_cart: true,
      once_per_cart_amount_cents: 500,
      ...discountConditions,
    };
    const cart: CartState = {
      items: [firstItem, secondItem],
      discountCodes: [
        { code: "CART", products: { product: cartDiscount, second: cartDiscount }, fromUrl: false },
        {
          code: "PRODUCT",
          products: { product: { type: "fixed", cents: 800, ...discountConditions } },
          fromUrl: false,
        },
      ],
    };

    expect(getDiscountedPrice(cart, firstItem).price).toBe(200);
    expect(getDiscountedPrice(cart, secondItem).price).toBe(500);
  });

  it("carries the discount left by the currency minimum onto the next line", () => {
    const secondProduct = { ...product, id: "second-id", permalink: "second" };
    const firstItem = { ...item, price: 100, quantity: 2 };
    const secondItem = { ...item, price: 1_000, quantity: 1, product: secondProduct };
    const discount = {
      type: "fixed" as const,
      cents: 199,
      once_per_cart: true,
      once_per_cart_amount_cents: 199,
      ...discountConditions,
    };
    const cart: CartState = {
      items: [firstItem, secondItem],
      discountCodes: [{ code: "SAVE", products: { product: discount, second: discount }, fromUrl: false }],
    };

    expect(getDiscountedPrice(cart, firstItem).price).toBe(99);
    expect(getDiscountedPrice(cart, secondItem).price).toBe(902);
  });

  it("keeps the allocation when pricing a copied cart item", () => {
    const cart = cartWith({
      type: "fixed",
      cents: 100,
      once_per_cart: true,
      once_per_cart_amount_cents: 100,
      ...discountConditions,
    });
    const copiedItem = { ...item, option_id: "offered-option" };

    expect(getDiscountedPrice(cart, copiedItem, item).price).toBe(1_900);
  });

  it("uses the offered option price when pricing a copied cart item", () => {
    const currentItem = { ...item, price: 1_000, quantity: 1 };
    const cart: CartState = {
      items: [currentItem],
      discountCodes: [
        {
          code: "SAVE",
          products: {
            product: {
              type: "fixed",
              cents: 1_500,
              once_per_cart: true,
              once_per_cart_amount_cents: 1_500,
              ...discountConditions,
            },
          },
          fromUrl: false,
        },
      ],
    };
    const offeredItem = { ...currentItem, price: 2_000, option_id: "offered-option" };

    expect(getDiscountedPrice(cart, offeredItem, currentItem).price).toBe(500);
  });

  it("allocates the remaining discount when pricing an additive cross-sell", () => {
    const crossSellProduct = { ...product, id: "cross-sell-id", permalink: "cross-sell" };
    const currentItem = { ...item, price: 1_000, quantity: 1 };
    const crossSellItem = { ...item, price: 1_000, quantity: 1, product: crossSellProduct };
    const discount = {
      type: "fixed" as const,
      cents: 1_500,
      once_per_cart: true,
      once_per_cart_amount_cents: 1_500,
      ...discountConditions,
    };
    const cart: CartState = {
      items: [currentItem],
      discountCodes: [{ code: "SAVE", products: { product: discount, "cross-sell": discount }, fromUrl: false }],
    };

    expect(getDiscountedPrice(cart, crossSellItem).price).toBe(500);
  });

  it("keeps the source identity when pricing a copy of the second duplicate line", () => {
    const firstItem = {
      ...item,
      option_id: "first-option",
      accepted_offer: {
        id: "upsell",
        discount: { type: "fixed" as const, cents: 200, ...discountConditions },
      },
    };
    const secondItem = { ...item, option_id: "second-option" };
    const cart = cartWith({
      type: "fixed",
      cents: 100,
      once_per_cart: true,
      once_per_cart_amount_cents: 100,
      ...discountConditions,
    });
    cart.items = [firstItem, secondItem];
    const copiedItem = { ...secondItem, option_id: "offered-option" };

    expect(getDiscountedPrice(cart, copiedItem, secondItem).price).toBe(1_900);
  });
});
