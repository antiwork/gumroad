import React from "react";

import { Membership, Product, SortKey } from "$app/data/products";

import { Icon } from "$app/components/Icons";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { PaginationProps } from "$app/components/Pagination";
import { Popover } from "$app/components/Popover";
import { ProductsLayout } from "$app/components/ProductsLayout";
import ProductsPage from "$app/components/ProductsPage";
import { Sort } from "$app/components/useSortingTableDriver";
import { WithTooltip } from "$app/components/WithTooltip";

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
  const searchInputRef = React.useRef<HTMLInputElement | null>(null);
  const [isSearchPopoverOpen, setIsSearchPopoverOpen] = React.useState(false);
  const [query, setQuery] = React.useState<string | null>(null);

  React.useEffect(() => {
    if (isSearchPopoverOpen) searchInputRef.current?.focus();
  }, [isSearchPopoverOpen]);

  return (
    <ProductsLayout
      selectedTab="archived"
      title="Products"
      archivedTabVisible
      ctaButton={
        <>
          <Popover
            open={isSearchPopoverOpen}
            onToggle={setIsSearchPopoverOpen}
            aria-label="Toggle Search"
            trigger={
              <WithTooltip tip="Search" position="bottom">
                <div className="button">
                  <Icon name="solid-search" />
                </div>
              </WithTooltip>
            }
          >
            <div className="input">
              <Icon name="solid-search" />
              <input
                ref={searchInputRef}
                type="text"
                placeholder="Search products"
                value={query ?? ""}
                onChange={(evt) => setQuery(evt.target.value)}
              />
            </div>
          </Popover>
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
