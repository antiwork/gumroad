// Structural subset of BundleProduct so both the bundle editor (BundleEdit/types.ts) and the
// Share tab's locally-typed products can share these helpers.
type PricedBundleProduct = {
  price_cents: number;
  quantity: number;
  variants: {
    selected_id: string;
    list: { id: string; price_difference: number }[];
  } | null;
};

export const computeStandalonePrice = (bundleProduct: PricedBundleProduct) =>
  (bundleProduct.price_cents +
    (bundleProduct.variants?.list.find(({ id }) => id === bundleProduct.variants?.selected_id)?.price_difference ??
      0)) *
  bundleProduct.quantity;

export const computeStandaloneTotalCents = (products: PricedBundleProduct[]) =>
  products.reduce((total, product) => total + computeStandalonePrice(product), 0);

export const computeDiscountedPriceCents = (standaloneTotalCents: number, discountPercent: number) =>
  Math.max(0, Math.round(standaloneTotalCents * (1 - discountPercent / 100)));
