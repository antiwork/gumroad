import * as React from "react";

import { Membership, Product, SortKey } from "$app/data/products";

import { PaginationProps } from "$app/components/Pagination";
import { Tab } from "$app/components/ProductsLayout";
import { ProductsPageMembershipsTable } from "$app/components/ProductsPage/MembershipsTable";
import { ProductsPageProductsTable } from "$app/components/ProductsPage/ProductsTable";
import { Sort } from "$app/components/useSortingTableDriver";

const ProductsPage = ({
  memberships,
  membershipsPagination,
  membershipsSort,
  products,
  productsPagination,
  productsSort,
  query,
  setEnableArchiveTab,
  type = "products",
}: {
  memberships: Membership[];
  membershipsPagination: PaginationProps;
  membershipsSort?: Sort<SortKey> | null | undefined;
  products: Product[];
  productsPagination: PaginationProps;
  productsSort?: Sort<SortKey> | null | undefined;
  query: string | null;
  setEnableArchiveTab?: (enable: boolean) => void;
  type?: Tab;
}) => {
  const hasResults = memberships.length > 0 || products.length > 0;

  return (
    <div className="grid gap-12">
      {/* Always render table components so their useOnChange search effects
          keep running even when the query returns zero results. The tables
          internally return null when their entries are empty. */}
      <ProductsPageMembershipsTable
        query={query}
        entries={memberships}
        pagination={membershipsPagination}
        sort={membershipsSort}
        selectedTab={type}
        setEnableArchiveTab={setEnableArchiveTab}
      />
      <ProductsPageProductsTable
        query={query}
        entries={products}
        pagination={productsPagination}
        sort={productsSort}
        selectedTab={type}
        setEnableArchiveTab={setEnableArchiveTab}
      />

      {!hasResults && query ? (
        <p className="text-muted text-center">No products found matching &ldquo;{query}&rdquo;</p>
      ) : null}
    </div>
  );
};

export default ProductsPage;
