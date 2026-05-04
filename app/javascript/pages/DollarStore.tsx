import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { SearchResults } from "$app/data/search";
import { CurrencyCode } from "$app/utils/currency";

import { CategoryFilter, Taxonomy } from "$app/components/DollarStore/CategoryFilter";
import { DollarStoreHeader } from "$app/components/DollarStore/Header";
import { DollarTile } from "$app/components/DollarStore/Tile";
import { HomeFooter } from "$app/components/Home/Shared/Footer";

type PriceMode = "paid" | "free_and_paid" | "include_pwyw";

type Props = {
  search_results: SearchResults;
  currency_code: CurrencyCode;
  price_mode: PriceMode;
  random_seed: number;
  search_offset: number;
  taxonomies: Taxonomy[];
  selected_taxonomy_path: string | null;
  selected_taxonomy_label: string | null;
};

function DollarStore() {
  const props = cast<Props>(usePage().props);
  const products = props.search_results.products;
  const [activeId, setActiveId] = React.useState<string | null>(null);

  return (
    <div className="flex min-h-screen flex-col bg-white text-black">
      <DollarStoreHeader />

      <CategoryFilter
        taxonomies={props.taxonomies}
        selectedPath={props.selected_taxonomy_path}
        selectedLabel={props.selected_taxonomy_label}
      />

      <main className="flex-1 px-4 pt-2 pb-16 lg:px-12">
        <div className="grid grid-cols-2 gap-x-12 gap-y-12 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5">
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
      </main>

      <HomeFooter />
    </div>
  );
}

DollarStore.loggedInUserLayout = true;
export default DollarStore;
