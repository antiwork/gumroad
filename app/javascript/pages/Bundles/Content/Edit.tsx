import { router, useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { AbortError, assertResponseError } from "$app/utils/request";

import { BundleContentUpdatedStatus } from "$app/components/BundleEdit/ContentTab/BundleContentUpdatedStatus";
import { BundleProductItem } from "$app/components/BundleEdit/ContentTab/BundleProductItem";
import { BundleProductSelector } from "$app/components/BundleEdit/ContentTab/BundleProductSelector";
import { BundleEditLayout } from "$app/components/BundleEdit/InertiaLayout";
import { BundleProduct, Bundle } from "$app/components/BundleEdit/state";
import { Button } from "$app/components/Button";
import { CartItemList } from "$app/components/CartItemList";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Card } from "$app/components/Product/Card";
import { showAlert } from "$app/components/server-components/Alert";
import { Placeholder } from "$app/components/ui/Placeholder";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";
import { useOnScrollToBottom } from "$app/components/useOnScrollToBottom";
import { useRunOnce } from "$app/components/useRunOnce";

type Props = {
  bundle: Bundle;
  id: string;
  unique_permalink: string;
  products_count: number;
  has_outdated_purchases: boolean;
  available_products?: BundleProduct[];
};

const RESULTS_PER_PAGE = 10;

export default function BundleContentEdit() {
  const props = cast<Props>(usePage().props);
  const { bundle: initialBundle, id, unique_permalink, products_count, has_outdated_purchases } = props;

  const form = useForm({
    products: initialBundle.products,
  });

  const [results, setResults] = React.useState<BundleProduct[]>([]);
  const [isLoading, setIsLoading] = React.useState(true);
  const [hasMoreResults, setHasMoreResults] = React.useState(true);
  const [query, setQuery] = React.useState("");

  const loadSearchResults = async ({ query = "", loadMore = false, all = false } = {}) => {
    if (!hasMoreResults && loadMore) return results;
    setIsLoading(true);
    let newResults = results;
    
    try {
      // Use partial reload to fetch products
      router.reload({
        only: ["available_products"],
        data: {
          query,
          from: loadMore ? results.length : 0,
          all,
          load_products: true,
        },
        preserveUrl: true,
        onSuccess: (page) => {
          const availableProducts = (page.props as any).available_products || [];
          newResults = loadMore ? [...results, ...availableProducts] : availableProducts;
          setResults(newResults);
          setHasMoreResults(!(all || newResults.length < RESULTS_PER_PAGE));
        },
        onError: (errors) => {
          showAlert(errors.base || "Failed to load products", "error");
        },
        onFinish: () => setIsLoading(false),
      });
    } catch (e) {
      if (e instanceof AbortError) return newResults;
      assertResponseError(e);
      showAlert(e.message, "error");
      setIsLoading(false);
    }
    
    return newResults;
  };

  useRunOnce(() => void loadSearchResults());
  
  useOnChange(
    useDebouncedCallback(() => void loadSearchResults({ query }), 300),
    [query]
  );

  const formRef = React.useRef<HTMLFormElement>(null);
  useOnScrollToBottom(
    formRef,
    () => {
      if (!isLoading) void loadSearchResults({ query, loadMore: true });
    },
    30
  );

  const [isSelecting, setIsSelecting] = React.useState(form.data.products.length > 0);

  const handleSubmit = (e?: React.FormEvent) => {
    e?.preventDefault();
    
    // Validate that at least one product is selected
    if (form.data.products.length === 0) {
      showAlert("Bundles must have at least one product.", "error");
      return;
    }

    // Transform products to match backend expectations
    const productsForBackend = form.data.products.map((product, index) => ({
      product_id: product.id,
      variant_id: product.variants?.selected_id || null,
      quantity: product.quantity,
      position: index,
    }));

    form.transform(() => ({ products: productsForBackend }));
    form.put(Routes.bundles_content_path(id), {
      preserveScroll: true,
    });
  };

  return (
    <BundleEditLayout
      bundleId={id}
      bundleName={initialBundle.name}
      uniquePermalink={unique_permalink}
      isPublished={initialBundle.is_published}
      currentTab="content"
      additionalActions={
        <Button color="primary" onClick={() => handleSubmit()} disabled={form.processing}>
          {form.processing ? "Saving..." : "Save changes"}
        </Button>
      }
      preview={
        <div>
          <header>
            <h1>Library</h1>
          </header>
          <section>
            <ProductCardGrid>
              {form.data.products.map((bundleProduct) => (
                <Card key={bundleProduct.id} product={bundleProduct} />
              ))}
            </ProductCardGrid>
          </section>
        </div>
      }
    >
      <form id="content-form" onSubmit={handleSubmit} ref={formRef}>
        <section className="p-4! md:p-8!">
          {has_outdated_purchases ? <BundleContentUpdatedStatus bundleId={id} /> : null}
          {isSelecting ? (
            <>
              <header
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  alignItems: "center",
                }}
              >
                <h2>Products</h2>
                <label>
                  <input
                    type="checkbox"
                    checked={form.data.products.length === products_count}
                    disabled={isLoading}
                    onChange={(evt) =>
                      evt.target.checked
                        ? void loadSearchResults({ query, loadMore: true, all: true }).then((results) =>
                            form.setData("products", results)
                          )
                        : form.setData("products", [])
                    }
                  />
                  All products
                </label>
              </header>
              {form.data.products.length > 0 ? (
                <CartItemList aria-label="Bundle products">
                  {form.data.products.map((bundleProduct, idx) => (
                    <BundleProductItem
                      key={bundleProduct.id}
                      bundleProduct={bundleProduct}
                      updateBundleProduct={(update) =>
                        form.setData("products", [
                          ...form.data.products.slice(0, idx),
                          { ...bundleProduct, ...update },
                          ...form.data.products.slice(idx + 1),
                        ])
                      }
                      removeBundleProduct={() =>
                        form.setData("products", form.data.products.filter(({ id }) => id !== bundleProduct.id))
                      }
                    />
                  ))}
                </CartItemList>
              ) : null}
              <div
                className="grid gap-4 rounded-sm border border-border bg-background p-4"
                aria-label="Product selector"
              >
                <div className="input">
                  <Icon name="solid-search" />
                  <input
                    type="text"
                    value={query}
                    onChange={(evt) => setQuery(evt.target.value)}
                    placeholder="Search products"
                  />
                </div>
                {isLoading && results.length === 0 ? (
                  <div style={{ justifySelf: "center" }}>
                    <LoadingSpinner />
                  </div>
                ) : results.length > 0 ? (
                  <CartItemList>
                    {results.map((bundleProduct) => {
                      const selected = form.data.products.some(({ id }) => id === bundleProduct.id);
                      return (
                        <BundleProductSelector
                          key={bundleProduct.id}
                          bundleProduct={bundleProduct}
                          selected={selected}
                          onToggle={() =>
                            form.setData(
                              "products",
                              selected
                                ? form.data.products.filter(({ id }) => id !== bundleProduct.id)
                                : [...form.data.products, bundleProduct]
                            )
                          }
                        />
                      );
                    })}
                  </CartItemList>
                ) : (
                  <div style={{ justifySelf: "center" }}>No products found</div>
                )}
              </div>
            </>
          ) : (
            <Placeholder>
              <h2>Select products</h2>
              <p>Choose the products you want to include in your bundle</p>
              <Button color="primary" onClick={() => setIsSelecting(true)}>
                <Icon name="plus" />
                Add products
              </Button>
            </Placeholder>
          )}
        </section>
      </form>
    </BundleEditLayout>
  );
}
