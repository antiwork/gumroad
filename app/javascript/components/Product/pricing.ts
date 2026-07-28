// Pricing helpers for the public product page. They live in their own module,
// away from the page components, so they can be unit tested without rendering
// the product page.

type BundleProductForPricing = { price: number };
type ProductForBundlePricing = { bundle_products: BundleProductForPricing[] };
type OptionForBundlePricing = { price_difference_cents: number | null };

// What the products inside a bundle cost when bought separately. Each entry is
// BundleProduct#standalone_price_cents on the server: the bundled product's own
// price plus the price difference of the one child variant the seller pinned
// when they built the bundle, times the quantity.
export const getStandalonePrice = (product: ProductForBundlePricing) =>
  product.bundle_products.reduce(
    (totalStandalonePrice, bundleProduct) => totalStandalonePrice + bundleProduct.price,
    0,
  );

// The price a bundle's price tag should show struck through as the "original
// price", or null when there is no honest comparison to show.
//
// A bundle can have versions of its own, which sellers use as tiers (a licence
// level, for example). Those bundle versions are unrelated to the child variants
// pinned inside the bundle: the pinned variants are fixed when the bundle is
// built, so the standalone sum describes exactly one tier — the one that adds
// nothing to the bundle's price. Picking a more expensive tier raises the price
// the buyer pays while leaving the standalone sum untouched, so the comparison
// silently understates the saving.
//
// Rather than show a reference price that does not describe what is being sold,
// we show no strikethrough on those tiers. Sellers who want a comparison on
// every tier need a way to state it themselves — tracked in gumroad-private#1453.
export const getBundleComparisonPriceCents = (
  product: ProductForBundlePricing,
  selectedOption: OptionForBundlePricing | null,
) => {
  if (product.bundle_products.length === 0) return null;
  if ((selectedOption?.price_difference_cents ?? 0) !== 0) return null;
  return getStandalonePrice(product);
};
