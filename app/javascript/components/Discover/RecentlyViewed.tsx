import * as React from "react";

import { CardProduct } from "$app/parsers/product";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Card } from "$app/components/Product/Card";
import { LinkButton } from "$app/components/ui/LinkButton";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";

export type RecentlyViewedProduct = CardProduct & { viewed_at: string };

export type RecentlyViewedProps = {
  products: RecentlyViewedProduct[];
  anonymous_key?: string | null;
};

// The views live server-side (keyed by user or browser guid), so "Clear" only records a
// client-side cutoff. Each product carries its own last-viewed timestamp so clearing hides
// exactly the products viewed before the cutoff, not the whole row keyed off the newest view —
// a re-view of any one product must not resurrect the others. The key is scoped per identity
// so one account's Clear does not hide another account's history in a shared browser. For
// anonymous visitors that identity is the server-derived `anonymous_key` (from the httponly
// `_gumroad_guid` the client can't read itself) rather than a shared "anonymous" bucket, so
// swapping the guid (cleared cookies, a fresh profile) doesn't inherit the old cutoff.
const clearedAtKey = (userId: string | null, anonymousKey: string | null) =>
  `gr_discover_recently_viewed_cleared_at:${userId ?? anonymousKey ?? "anonymous"}`;

const getClearedAt = (key: string): number | null => {
  try {
    const stored = localStorage.getItem(key);
    if (!stored) return null;
    const parsed = Date.parse(stored);
    return Number.isNaN(parsed) ? null : parsed;
  } catch {
    return null;
  }
};

export const RecentlyViewed = ({ data }: { data?: RecentlyViewedProps | null | undefined }) => {
  const storageKey = clearedAtKey(useLoggedInUser()?.id ?? null, data?.anonymous_key ?? null);
  const [state, setState] = React.useState(() => ({ key: storageKey, clearedAt: getClearedAt(storageKey) }));
  // Re-derive during render (not in an effect) when the identity-derived key changes — e.g. an
  // anonymous visitor signs in without a full page reload — so a stale cutoff from the
  // previous identity can't outlive it.
  const clearedAt = state.key === storageKey ? state.clearedAt : getClearedAt(storageKey);
  if (state.key !== storageKey) setState({ key: storageKey, clearedAt });

  if (!data?.products.length) return null;

  const products =
    clearedAt == null ? data.products : data.products.filter((product) => Date.parse(product.viewed_at) > clearedAt);
  if (!products.length) return null;

  const clear = () => {
    const now = Date.now();
    try {
      localStorage.setItem(storageKey, new Date(now).toISOString());
    } catch {}
    setState({ key: storageKey, clearedAt: now });
  };

  return (
    <section className="flex flex-col gap-4">
      <header className="flex items-center justify-between">
        <h2>Recently viewed</h2>
        <LinkButton onClick={clear}>Clear</LinkButton>
      </header>
      <ProductCardGrid>
        {products.map((product) => (
          <Card key={product.id} product={product} eager={false} />
        ))}
      </ProductCardGrid>
    </section>
  );
};
