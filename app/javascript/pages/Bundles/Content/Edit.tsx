import { Plus, Search } from "@boxicons/react";
import { router, useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { cast } from "$app/utils/cast";

import { BundleContentUpdatedStatus } from "$app/components/BundleEdit/ContentTab/BundleContentUpdatedStatus";
import { BundleProductItem } from "$app/components/BundleEdit/ContentTab/BundleProductItem";
import { BundleProductSelector } from "$app/components/BundleEdit/ContentTab/BundleProductSelector";
import { BundleEditLayout, useProductUrl } from "$app/components/BundleEdit/Layout";
import { BundleProduct } from "$app/components/BundleEdit/types";
import { Button } from "$app/components/Button";
import { CartItemList } from "$app/components/CartItemList";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Card } from "$app/components/Product/Card";
import { PublishSchedule } from "$app/components/PublishScheduleCard";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
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
    publish_schedule?: PublishSchedule | null;
    can_create_publish_schedule?: boolean;
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

  const searchProducts = React.useCallback(
    (options: { query?: string; page?: number; reset?: string[]; preserveUrl?: boolean }) => {
      const data: { query?: string | undefined; page?: number } = {};
      if (options.query !== undefined) data.query = options.query || undefined;
      if (options.page !== undefined) data.page = options.page;

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

  React.useEffect(() => () => debouncedSearch.cancel(), [debouncedSearch]);

  useOnChange(() => debouncedSearch(query), [query]);

  const loadMore = () => {
    if (!hasMoreResults || isSearchLoading) return;
    searchProducts({ query, page: currentPage + 1, preserveUrl: true });
  };

  const loadAll = () => {
    debouncedSearch.cancel();
    router.reload({
      data: { query: query || undefined, all: true },
      only: ["search_data"],
      reset: ["search_data"],
      preserveUrl: true,
      onStart: () => setIsSearchLoading(true),
      onFinish: () => setIsSearchLoading(false),
      onSuccess: ({ props }) => {
        const matches = cast<ContentPageProps>(props).search_data?.products;
        if (!matches?.length) return;
        form.setData((data) => {
          const selectedById = new Map(data.products.map((product) => [product.id, product]));
          if (selectedById.size === matches.length && matches.every(({ id }) => selectedById.has(id))) return data;
          return { ...data, products: matches.map((product) => selectedById.get(product.id) ?? product) };
        });
      },
    });
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
      publishSchedule={bundle.publish_schedule ?? null}
      canCreatePublishSchedule={bundle.can_create_publish_schedule ?? false}
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
        <section className="grid gap-8 p-4! md:p-8!">
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
                <Label>
                  <Checkbox
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
                </Label>
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
                <InputGroup>
                  <Search className="size-5 text-muted" />
                  <Input
                    type="text"
                    value={query}
                    onChange={(evt) => setQuery(evt.target.value)}
                    placeholder="Search products"
                  />
                </InputGroup>
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
                <Plus className="size-5" />
                Add products
              </Button>
            </Placeholder>
          )}
        </section>
      </form>
    </BundleEditLayout>
  );
}
