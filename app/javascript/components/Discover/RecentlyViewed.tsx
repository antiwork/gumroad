import * as React from "react";

import { CardProduct } from "$app/parsers/product";

import { Card } from "$app/components/Product/Card";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";

export type RecentlyViewedProps = {
  products: CardProduct[];
  latest_viewed_at: string;
};

const CLEARED_AT_KEY = "gr_discover_recently_viewed_cleared_at";

// The views live server-side (keyed by user or browser guid), so "Clear" only records a
// client-side cutoff: anything viewed before it stays hidden, and the row reappears once
// the visitor views another product.
const getClearedAt = (): string | null => {
  try {
    return localStorage.getItem(CLEARED_AT_KEY);
  } catch {
    return null;
  }
};

export const RecentlyViewed = ({ data }: { data?: RecentlyViewedProps | null }) => {
  const [clearedAt, setClearedAt] = React.useState<string | null>(getClearedAt);

  if (!data || !data.products.length) return null;
  if (clearedAt && data.latest_viewed_at <= clearedAt) return null;

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
        {data.products.map((product) => (
          <Card key={product.id} product={product} eager={false} />
        ))}
      </ProductCardGrid>
    </section>
  );
};
