import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { Search } from "$app/components/Search";
import { NavigationButtonInertia } from "$app/components/ui/NavigationButton";

type Props = {
  query: string;
  setQuery: (query: string) => void;
};

type PageProps = {
  has_products: boolean;
  can_create_product: boolean;
};

export const HeaderButtons = ({ query, setQuery }: Props) => {
  const { can_create_product: canCreateProduct, has_products: hasProducts } = cast<PageProps>(usePage().props);

  return (
    <>
      {hasProducts ? <Search value={query} onSearch={setQuery} placeholder="Search products" /> : null}
      <NavigationButtonInertia href={Routes.new_product_path()} disabled={!canCreateProduct} color="accent">
        New product
      </NavigationButtonInertia>
    </>
  );
};
