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
}) => (
  <div className="grid gap-12">
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
  </div>
);

export default ProductsPage;
