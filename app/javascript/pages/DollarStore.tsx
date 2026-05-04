import { router, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { SearchRequest, SearchResults } from "$app/data/search";
import { CurrencyCode } from "$app/utils/currency";
import { getRootTaxonomy, getRootTaxonomyImage } from "$app/utils/discover";

import { Button } from "$app/components/Button";
import { CategoryFilter, Taxonomy } from "$app/components/DollarStore/CategoryFilter";
import { DollarStoreHeader } from "$app/components/DollarStore/Header";
import { DollarTile } from "$app/components/DollarStore/Tile";
import { HomeFooter } from "$app/components/Home/Shared/Footer";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Card } from "$app/components/Product/Card";
import { useSearchReducer } from "$app/components/Product/CardGrid";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";

import merchandiseIcon from "$assets/images/discover/merchandise.svg";

type PriceMode = "paid" | "free_and_paid" | "include_pwyw";

type Props = {
  search_results: SearchResults;
  currency_code: CurrencyCode;
  price_mode: PriceMode;
  search_offset: number;
  taxonomies: Taxonomy[];
  selected_taxonomy_path: string | null;
  selected_taxonomy_label: string | null;
};

function DollarStore() {
  const props = cast<Props>(usePage().props);
  const [activeId, setActiveId] = React.useState<string | null>(null);

  const initialParams: SearchRequest = {
    from: props.search_offset,
    sort: "highest_rated",
    max_price: 1,
    taxonomy: props.selected_taxonomy_path ?? undefined,
  };
  const [state, dispatch] = useSearchReducer({ params: initialParams, results: props.search_results });
  const products = state.results?.products ?? [];
  const total = state.results?.total ?? 0;
  const showLoadMore = total > (state.offset ?? 0) + products.length;
  const isEmpty = !state.loading && products.length === 0;

  return (
    <div
      className="flex min-h-screen flex-col bg-white text-black"
      style={{ "--filled": "255 255 255", "--color": "0 0 0" }}
    >
      <DollarStoreHeader taxonomies={props.taxonomies} selectedPath={props.selected_taxonomy_path} />

      <CategoryFilter
        taxonomies={props.taxonomies}
        selectedPath={props.selected_taxonomy_path}
        selectedLabel={props.selected_taxonomy_label}
      />

      <main className="flex-1 px-4 pt-2 pb-16 lg:px-12">
        {isEmpty ? (
          <EmptyState
            taxonomies={props.taxonomies}
            selectedPath={props.selected_taxonomy_path}
            selectedLabel={props.selected_taxonomy_label}
          />
        ) : (
          <>
            <ProductCardGrid className="lg:hidden [&_article]:border-black! [&_article]:bg-white! [&_article]:text-black! [&_article_*]:border-black/15!">
              {products.map((product) => (
                <Card key={product.id} product={product} />
              ))}
            </ProductCardGrid>
            <div className="hidden gap-x-12 gap-y-12 lg:grid lg:grid-cols-4 xl:grid-cols-5">
              {products.map((product) => (
                <DollarTile
                  key={product.id}
                  product={product}
                  isAnyActive={activeId !== null}
                  isActive={activeId === product.id}
                  onActivate={setActiveId}
                />
              ))}
            </div>
          </>
        )}

        {showLoadMore ? (
          <div className="mt-12 flex justify-center">
            <Button
              onClick={() => dispatch({ type: "load-more" })}
              disabled={state.loading}
              className="border border-black"
            >
              {state.loading ? <LoadingSpinner /> : "Load more"}
            </Button>
          </div>
        ) : null}
      </main>

      <HomeFooter />
    </div>
  );
}

type EmptyStateProps = {
  taxonomies: Taxonomy[];
  selectedPath: string | null;
  selectedLabel: string | null;
};

const EmptyState = ({ taxonomies, selectedPath, selectedLabel }: EmptyStateProps) => {
  const rootSlug = getRootTaxonomy(selectedPath ?? undefined);
  const iconUrl = rootSlug ? getRootTaxonomyImage(rootSlug) : merchandiseIcon;

  const segments = selectedPath?.split("/") ?? [];
  const isLeaf = segments.length > 1;

  let suggestionLabel: string;
  let suggestionPath: string | null;

  if (isLeaf) {
    const parentSlugs = segments.slice(0, -1);
    let node: Taxonomy | undefined;
    for (const slug of parentSlugs) {
      const parentKey = node?.key ?? null;
      node = taxonomies.find((t) => t.slug === slug && t.parent_key === parentKey);
      if (!node) break;
    }
    suggestionLabel = `All ${node?.label ?? parentSlugs[parentSlugs.length - 1]}`;
    suggestionPath = parentSlugs.join("/");
  } else {
    suggestionLabel = "All products";
    suggestionPath = null;
  }

  const navigate = (path: string | null) => {
    const data = path ? { taxonomy: path } : {};
    router.get(Routes.dollar_store_path(), data, { preserveScroll: true, preserveState: false });
  };

  return (
    <div className="flex flex-col items-center justify-center gap-6 px-4 py-24 text-center">
      <img src={iconUrl} aria-hidden alt="" className="h-32 w-auto opacity-60" />
      <p className="text-2xl text-black">No products in {selectedLabel ? `"${selectedLabel}"` : "this category"}</p>
      <button
        type="button"
        onClick={() => navigate(suggestionPath)}
        className="cursor-pointer border-b border-black bg-transparent text-xl text-black hover:opacity-70"
      >
        Try exploring {suggestionLabel}
      </button>
    </div>
  );
};

DollarStore.loggedInUserLayout = true;
export default DollarStore;
