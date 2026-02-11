import React from "react";

import { Membership, Product, SortKey } from "$app/data/products";

import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { PaginationProps } from "$app/components/Pagination";
import { ProductsLayout } from "$app/components/ProductsLayout";
import ProductsPage from "$app/components/ProductsPage";
import { Search } from "$app/components/Search";
import { Sort } from "$app/components/useSortingTableDriver";

export type ArchivedProductsPageProps = {
  products_data: {
    products: Product[];
    pagination: PaginationProps;
    sort?: Sort<SortKey> | null | undefined;
  };
  memberships_data: {
    memberships: Membership[];
    pagination: PaginationProps;
    sort?: Sort<SortKey> | null | undefined;
  };
  can_create_product: boolean;
};

export const ArchivedProductsPage = ({
  products_data: { products, pagination: productsPagination, sort: productsSort },
  memberships_data: { memberships, pagination: membershipsPagination, sort: membershipsSort },
  can_create_product: canCreateProduct,
}: ArchivedProductsPageProps) => {
  const [query, setQuery] = React.useState<string | null>(null);

  return (
    <ProductsLayout
      selectedTab="archived"
      title="Products"
      archivedTabVisible
      ctaButton={
        <>
          <Search value={query ?? ""} onSearch={setQuery} placeholder="Search products" />
          <NavigationButtonInertia href={Routes.new_product_path()} disabled={!canCreateProduct} color="accent">
            New product
          </NavigationButtonInertia>
        </>
      }
    >
      <section className="p-4 md:p-8">
        <ProductsPage
          memberships={memberships}
          membershipsPagination={membershipsPagination}
          membershipsSort={membershipsSort}
          products={products}
          productsPagination={productsPagination}
          productsSort={productsSort}
          query={query}
          type="archived"
        />
      </section>
    </ProductsLayout>
  );
};

export default ArchivedProductsPage;
