import { router, useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { BundleContentUpdatedStatus } from "$app/components/BundleEdit/ContentTab/BundleContentUpdatedStatus";
import { BundleProductItem } from "$app/components/BundleEdit/ContentTab/BundleProductItem";
import { BundleProductSelector } from "$app/components/BundleEdit/ContentTab/BundleProductSelector";
import { BundleEditLayout, useProductUrl } from "$app/components/BundleEdit/Layout";
import { BundleProduct } from "$app/components/BundleEdit/types";
import { Button } from "$app/components/Button";
import { CartItemList } from "$app/components/CartItemList";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Card } from "$app/components/Product/Card";
import { Placeholder } from "$app/components/ui/Placeholder";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";
import { useOnScrollToBottom } from "$app/components/useOnScrollToBottom";

type ContentPageProps = {
  bundle: {
    name: string;
    is_published: boolean;
    products: BundleProduct[];
    custom_permalink: string | null;
  };
  id: string;
  unique_permalink: string;
  products_count: number;
  has_outdated_purchases: boolean;
  search_data?: {
    products: BundleProduct[];
    has_more: boolean;
    page: number;
  };
};

type ContentFormData = {
  products: BundleProduct[];
  publish?: boolean;
  unpublish?: boolean;
  redirect_to?: string;
};

export default function BundlesContentEdit() {
  const page = usePage();
  const props = cast<ContentPageProps>(page.props);
  const {
    bundle,
    id,
    unique_permalink,
    products_count,
    has_outdated_purchases,
    search_data: initialSearchData,
  } = props;

  const url = useProductUrl(unique_permalink, bundle.custom_permalink);

  const searchData = initialSearchData;
  const results = searchData?.products || [];
  const hasMoreResults = searchData?.has_more ?? false;
  const currentPage = searchData?.page ?? 1;
  const [isSearchLoading, setIsSearchLoading] = React.useState(false);
  const [query, setQuery] = React.useState("");

  const form = useForm<ContentFormData>({
    products: bundle.products,
  });

  const lastProcessedResultsRef = React.useRef<string>("");
  React.useEffect(() => {
    const urlParams = new URLSearchParams(window.location.search);
    if (urlParams.get("all") === "true" && results.length > 0) {
      const resultsKey = results
        .map((p) => p.id)
        .sort()
        .join(",");
      if (lastProcessedResultsRef.current !== resultsKey) {
        lastProcessedResultsRef.current = resultsKey;
        const currentProductIds = new Set(form.data.products.map((p) => p.id));
        const newProductIds = new Set(results.map((p) => p.id));
        const areEqual =
          currentProductIds.size === newProductIds.size && [...currentProductIds].every((id) => newProductIds.has(id));
        if (!areEqual) {
          form.setData("products", results);
        }
      }
    } else if (urlParams.get("all") !== "true") {
      lastProcessedResultsRef.current = "";
    }
  }, [results, form.data.products, form]);

  const searchProducts = React.useCallback(
    (options: { query?: string; page?: number; all?: boolean; reset?: string[]; preserveUrl?: boolean }) => {
      const data: { query?: string; page?: number; all?: boolean } = {};
      if (options.query) data.query = options.query;
      if (options.page !== undefined) data.page = options.page;
      if (options.all !== undefined) data.all = options.all;

      router.reload({
        data,
        only: ["search_data"],
        ...(options.reset && { reset: options.reset }),
        ...(options.preserveUrl && { preserveUrl: options.preserveUrl }),
        onStart: () => setIsSearchLoading(true),
        onFinish: () => setIsSearchLoading(false),
      });
    },
    [],
  );

  const debouncedSearch = useDebouncedCallback((searchQuery: string) => {
    searchProducts({ query: searchQuery, reset: ["search_data"] });
  }, 300);

  useOnChange(() => debouncedSearch(query), [query]);

  const loadMore = () => {
    if (!hasMoreResults || isSearchLoading) return;
    searchProducts({ query, page: currentPage + 1, preserveUrl: true });
  };

  const loadAll = () => {
    searchProducts({ query, all: true, reset: ["search_data"] });
  };

  const formRef = React.useRef<HTMLFormElement>(null);
  useOnScrollToBottom(
    formRef,
    () => {
      if (!isSearchLoading) loadMore();
    },
    30,
  );

  const [isSelecting, setIsSelecting] = React.useState(form.data.products.length > 0);

  const transformContentData = () => ({
    products: form.data.products.map((bundleProduct, idx) => ({
      product_id: bundleProduct.id,
      variant_id: bundleProduct.variants?.selected_id,
      quantity: bundleProduct.quantity,
      position: idx,
    })),
  });

  const submitForm = (additionalData: Partial<ContentFormData> = {}) => {
    if (form.processing) return;
    form.transform(() => ({ ...transformContentData(), ...additionalData }));
    form.put(Routes.bundle_content_path(id), { preserveScroll: true });
  };

  const handleSave = () => submitForm();
  const handlePublish = () => submitForm({ publish: true });
  const handleUnpublish = () => submitForm({ unpublish: true });
  const handlePreview = () => {
    window.open(url);
  };
  const saveBeforeNavigate = (targetPath: string) => {
    if (!form.isDirty) return false;
    submitForm({ redirect_to: targetPath });
    return true;
  };

  const updateProducts = (newProducts: BundleProduct[]) => {
    form.setData("products", newProducts);
  };

  const updateBundleProduct = (idx: number, update: Partial<BundleProduct>) => {
    const products = form.data.products.map(
      (product, i): BundleProduct => (i === idx ? { ...product, ...update } : product),
    );
    form.setData("products", products);
  };

  const removeBundleProduct = (productId: string) => {
    form.setData(
      "products",
      form.data.products.filter(({ id }) => id !== productId),
    );
  };

  const toggleProductSelection = (bundleProduct: BundleProduct, selected: boolean) => {
    if (selected) {
      form.setData(
        "products",
        form.data.products.filter(({ id }) => id !== bundleProduct.id),
      );
    } else {
      form.setData("products", [...form.data.products, bundleProduct]);
    }
  };

  return (
    <BundleEditLayout
      id={id}
      name={bundle.name}
      customPermalink={bundle.custom_permalink}
      uniquePermalink={unique_permalink}
      isPublished={bundle.is_published}
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
      {...(bundle.is_published && { onSave: handleSave })}
      {...(bundle.is_published && { onUnpublish: handleUnpublish })}
      {...(!bundle.is_published && { onPublish: handlePublish })}
      {...(bundle.is_published && { onPreview: handlePreview })}
      isProcessing={form.processing}
      onBeforeNavigate={saveBeforeNavigate}
    >
      <form onSubmit={(evt) => evt.preventDefault()} ref={formRef}>
        <section className="p-4! md:p-8!">
          {has_outdated_purchases ? <BundleContentUpdatedStatus id={id} /> : null}
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
                    disabled={isSearchLoading}
                    onChange={(evt) => {
                      if (evt.target.checked) {
                        loadAll();
                      } else {
                        updateProducts([]);
                      }
                    }}
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
                      updateBundleProduct={(update) => updateBundleProduct(idx, update)}
                      removeBundleProduct={() => removeBundleProduct(bundleProduct.id)}
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
                {isSearchLoading && results.length === 0 ? (
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
                          onToggle={() => toggleProductSelection(bundleProduct, selected)}
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
