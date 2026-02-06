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
  // Track if tables had entries on initial load to keep them mounted during search
  // This ensures the search useEffect continues to run even when results are empty
  const hadInitialMemberships = React.useRef(memberships.length > 0);
  const hadInitialProducts = React.useRef(products.length > 0);

  return (
    <div className="grid gap-12">
      {hadInitialMemberships.current ? (
        <ProductsPageMembershipsTable
          query={query}
          entries={memberships}
          pagination={membershipsPagination}
          sort={membershipsSort}
          selectedTab={type}
          setEnableArchiveTab={setEnableArchiveTab}
        />
      ) : null}

      {hadInitialProducts.current ? (
        <ProductsPageProductsTable
          query={query}
          entries={products}
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
