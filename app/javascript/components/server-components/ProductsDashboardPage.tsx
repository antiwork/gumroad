import React from "react";

import { Membership, Product } from "$app/data/products";

import { NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { PaginationProps } from "$app/components/Pagination";
import { Popover } from "$app/components/Popover";
import { ProductsLayout } from "$app/components/ProductsLayout";
import { WithTooltip } from "$app/components/WithTooltip";

import ProductsPage from "./ProductsPage";

import placeholder from "$assets/images/product_nudge.svg";

export type ProductsDashboardPageProps = {
  memberships: Membership[];
  memberships_pagination: PaginationProps;
  products: Product[];
  products_pagination: PaginationProps;
  archived_products_count: number;
  can_create_product: boolean;
};

export const ProductsDashboardPage = ({
  memberships,
  memberships_pagination: membershipsPagination,
  products,
  products_pagination: productsPagination,
  archived_products_count: archivedProductsCount,
  can_create_product: canCreateProduct,
}: ProductsDashboardPageProps) => {
  const [enableArchiveTab, setEnableArchiveTab] = React.useState(archivedProductsCount > 0);
  const searchInputRef = React.useRef<HTMLInputElement>(null);
  const [isSearchPopoverOpen, setIsSearchPopoverOpen] = React.useState(false);
  const [query, setQuery] = React.useState<string | null>(null);

  React.useEffect(() => {
    if (isSearchPopoverOpen) searchInputRef.current?.focus();
  }, [isSearchPopoverOpen]);

  return (
    <ProductsLayout
      selectedTab="products"
      title="Products"
      archivedTabVisible={enableArchiveTab}
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
          <NavigationButton href={Routes.new_product_path()} disabled={!canCreateProduct} color="accent">
            New product
          </NavigationButton>
        </>
      }
    >
      <section className="p-4 md:p-8">
        {memberships.length === 0 && products.length === 0 ? (
          <div className="placeholder">
            <figure>
              <img src={placeholder} />
            </figure>
            <h2>We’ve never met an idea we didn’t like.</h2>
            <p>Your first product doesn’t need to be perfect. Just put it out there, and see if it sticks.</p>
            <div>
              <NavigationButton href={Routes.new_product_path()} disabled={!canCreateProduct} color="accent">
                New product
              </NavigationButton>
            </div>
            <span>
              or{" "}
              <a href="/help/article/304-products-dashboard" target="_blank" rel="noreferrer">
                learn more about the products dashboard
              </a>
            </span>
          </div>
        ) : (
          <ProductsPage
            memberships={memberships}
            membershipsPagination={membershipsPagination}
            products={products}
            productsPagination={productsPagination}
            query={query}
            setEnableArchiveTab={setEnableArchiveTab}
          />
        )}
      </section>
    </ProductsLayout>
  );
};

export default ProductsDashboardPage;
