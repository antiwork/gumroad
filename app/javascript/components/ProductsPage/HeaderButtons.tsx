import { usePage } from "@inertiajs/react";
import React from "react";

import { cast } from "$app/utils/cast";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { Search } from "$app/components/Search";

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
  // On a wide screen the header nav carries "New product" on every page.
  const headerNav = !!useLoggedInUser()?.headerNav;

  return (
    <>
      {hasProducts ? <Search value={query} onSearch={setQuery} placeholder="Search products" /> : null}
      <NavigationButtonInertia
        href={Routes.new_product_path()}
        disabled={!canCreateProduct}
        color="accent"
        className={headerNav ? "lg:hidden" : undefined}
      >
        New product
      </NavigationButtonInertia>
    </>
  );
};
