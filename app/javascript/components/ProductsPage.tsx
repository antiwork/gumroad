import * as React from "react";

import { Membership, Product, SortKey } from "$app/data/products";

import { PaginationProps } from "$app/components/Pagination";
import { useWarmProductEditPage } from "$app/components/ProductEdit/load";
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
  // Almost every visit to this page ends with the seller opening one of these products, so fetch
  // the product editor's JavaScript now, while they are still reading the list. It is the largest
  // page in the dashboard, and waiting until the click means waiting on the network with nothing
  // on screen — which is what made sellers think their click hadn't registered
  // (gumroad-private#1469).
  const forceFullPageProductEditNavigation = useWarmProductEditPage();

  return (
    <div className="grid gap-12">
      {memberships.length > 0 ? (
        <ProductsPageMembershipsTable
          query={query}
          entries={memberships}
          pagination={membershipsPagination}
          sort={membershipsSort}
          selectedTab={type}
          setEnableArchiveTab={setEnableArchiveTab}
        />
      ) : null}

      {products.length > 0 ? (
        <ProductsPageProductsTable
          query={query}
          entries={products}
          forceFullPageProductEditNavigation={forceFullPageProductEditNavigation}
          pagination={productsPagination}
          sort={productsSort}
          selectedTab={type}
          setEnableArchiveTab={setEnableArchiveTab}
        />
      ) : null}
    </div>
  );
};

export default ProductsPage;
