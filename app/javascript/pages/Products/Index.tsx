import { Deferred, usePage } from "@inertiajs/react";
import React from "react";

import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { ProductsLayout } from "$app/components/ProductsLayout";
import ProductsPage from "$app/components/ProductsPage";
import { ProductsContentLoading } from "$app/components/ProductsPage/ContentLoading";
import { HeaderButtons } from "$app/components/ProductsPage/HeaderButtons";
import { type ProductsPageProps } from "$app/components/ProductsPage/ProductsPageProps";
import { useProductsSearch } from "$app/components/ProductsPage/useProductsSearch";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";

import placeholder from "$assets/images/product_nudge.svg";

type ProductsIndexPageProps = ProductsPageProps & {
  archived_products_count: number;
};

const ProductsContent = ({
  query,
  setEnableArchiveTab,
}: {
  query: string;
  setEnableArchiveTab: (enable: boolean) => void;
}) => {
  const {
    memberships_data,
    products_data,
    can_create_product: canCreateProduct,
  } = usePage<ProductsIndexPageProps>().props;
  const { memberships, pagination: membershipsPagination, sort: membershipsSort } = memberships_data;
  const { products, pagination: productsPagination, sort: productsSort } = products_data;

  return (
    <section className="p-4 md:p-8">
      {memberships.length === 0 && products.length === 0 ? (
        <Placeholder>
          <PlaceholderImage src={placeholder} />
          <h2>We've never met an idea we didn't like.</h2>
          <p>Your first product doesn't need to be perfect. Just put it out there, and see if it sticks.</p>
          <div>
            <NavigationButtonInertia href={Routes.new_product_path()} disabled={!canCreateProduct} color="accent">
              New product
            </NavigationButtonInertia>
          </div>
          <span>
            or{" "}
            <a href="/help/article/304-products-dashboard" target="_blank" rel="noreferrer">
              learn more about the products dashboard
            </a>
          </span>
        </Placeholder>
      ) : (
        <ProductsPage
          memberships={memberships}
          membershipsPagination={membershipsPagination}
          membershipsSort={membershipsSort}
          products={products}
          productsPagination={productsPagination}
          productsSort={productsSort}
          query={query}
          setEnableArchiveTab={setEnableArchiveTab}
        />
      )}
    </section>
  );
};

const ProductsIndexPage = () => {
  const { archived_products_count: archivedProductsCount } = usePage<ProductsIndexPageProps>().props;
  const [enableArchiveTab, setEnableArchiveTab] = React.useState(archivedProductsCount > 0);

  const { query, setQuery } = useProductsSearch();

  return (
    <ProductsLayout
      selectedTab="products"
      title="Products"
      archivedTabVisible={enableArchiveTab}
      ctaButton={<HeaderButtons query={query} setQuery={setQuery} />}
    >
      <Deferred data={["memberships_data", "products_data"]} fallback={<ProductsContentLoading />}>
        <ProductsContent query={query} setEnableArchiveTab={setEnableArchiveTab} />
      </Deferred>
    </ProductsLayout>
  );
};

export default ProductsIndexPage;
