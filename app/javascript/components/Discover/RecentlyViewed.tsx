import * as React from "react";

import { CardProduct } from "$app/parsers/product";

import { Card } from "$app/components/Product/Card";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";

export type RecentlyViewedProduct = CardProduct & { viewed_at: string };

export type RecentlyViewedProps = {
  products: RecentlyViewedProduct[];
};

const CLEARED_AT_KEY = "gr_discover_recently_viewed_cleared_at";

// The views live server-side (keyed by user or browser guid), so "Clear" only records a
// client-side cutoff. Each product carries its own last-viewed timestamp so clearing hides
// exactly the products viewed before the cutoff, not the whole row keyed off the newest view —
// a re-view of any one product must not resurrect the others.
const getClearedAt = (): string | null => {
  try {
    return localStorage.getItem(CLEARED_AT_KEY);
  } catch {
    return null;
  }
};

export const RecentlyViewed = ({ data }: { data?: RecentlyViewedProps | null | undefined }) => {
  const [clearedAt, setClearedAt] = React.useState<string | null>(getClearedAt);

  if (!data?.products.length) return null;

  const products = clearedAt ? data.products.filter((product) => product.viewed_at > clearedAt) : data.products;
  if (!products.length) return null;

  const clear = () => {
    const now = new Date().toISOString();
    try {
      localStorage.setItem(CLEARED_AT_KEY, now);
    } catch {}
    setClearedAt(now);
  };

  return (
    <section className="flex flex-col gap-4">
      <header className="flex items-center justify-between">
        <h2>Recently viewed</h2>
        <button className="cursor-pointer underline all-unset" onClick={clear}>
          Clear
        </button>
      </header>
      <ProductCardGrid>
        {products.map((product) => (
          <Card key={product.id} product={product} eager={false} />
        ))}
      </ProductCardGrid>
    </section>
  );
};
