import * as React from "react";

import { Membership, Product } from "$app/data/products";

import { PaginationProps } from "$app/components/Pagination";
import { Tab } from "$app/components/ProductsLayout";
import { ProductsPageMembershipsTable } from "$app/components/ProductsPage/MembershipsTable";
import { ProductsPageProductsTable } from "$app/components/ProductsPage/ProductsTable";

const ProductsPage = ({
  memberships,
  membershipsPagination,
  products,
  productsPagination,
  query,
  setEnableArchiveTab,
  type = "products",
}: {
  memberships: Membership[];
  membershipsPagination: PaginationProps;
  products: Product[];
  productsPagination: PaginationProps;
  query: string | null;
  setEnableArchiveTab?: (enable: boolean) => void;
  type?: Tab;
}) => (
  <div className="override grid gap-12">
    {memberships.length > 0 ? (
      <ProductsPageMembershipsTable
        query={query}
        entries={memberships}
        pagination={membershipsPagination}
        selectedTab={type}
        setEnableArchiveTab={setEnableArchiveTab}
      />
    ) : null}

    {products.length > 0 ? (
      <ProductsPageProductsTable
        query={query}
        entries={products}
        pagination={productsPagination}
        selectedTab={type}
        setEnableArchiveTab={setEnableArchiveTab}
      />
    ) : null}
  </div>
);

export default ProductsPage;
