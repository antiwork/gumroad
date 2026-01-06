import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { searchProducts } from "$app/data/bundle";
import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";
import { AbortError, assertResponseError } from "$app/utils/request";

import { BundleContentUpdatedStatus } from "$app/components/BundleEdit/ContentTab/BundleContentUpdatedStatus";
import { BundleProductItem } from "$app/components/BundleEdit/ContentTab/BundleProductItem";
import { BundleProductSelector } from "$app/components/BundleEdit/ContentTab/BundleProductSelector";
import { InertiaLayout } from "$app/components/BundleEdit/InertiaLayout";
import { Bundle, BundleEditContext, BundleProduct } from "$app/components/BundleEdit/state";
import { Button } from "$app/components/Button";
import { CartItemList } from "$app/components/CartItemList";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Card } from "$app/components/Product/Card";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { ProfileSection } from "$app/components/ProductEdit/state";
import { showAlert } from "$app/components/server-components/Alert";
import { Placeholder } from "$app/components/ui/Placeholder";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";
import { useOnScrollToBottom } from "$app/components/useOnScrollToBottom";
import { useRunOnce } from "$app/components/useRunOnce";

export type BundleContentProps = {
  bundle: Bundle;
  id: string;
  unique_permalink: string;
  currency_type: CurrencyCode;
  thumbnail: Thumbnail | null;
  sales_count_for_inventory: number;
  ratings: RatingsWithPercentages;
  taxonomies: Taxonomy[];
  profile_sections: ProfileSection[];
  refund_policies: OtherRefundPolicy[];
  products_count: number;
  is_bundle: boolean;
  has_outdated_purchases: boolean;
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
};

const RESULTS_PER_PAGE = 10;

export default function BundleContent() {
  const {
    bundle: initialBundle,
    id,
    unique_permalink,
    currency_type,
    thumbnail,
    sales_count_for_inventory,
    ratings,
    taxonomies,
    profile_sections,
    refund_policies,
    products_count,
    has_outdated_purchases,
    seller_refund_policy_enabled,
    seller_refund_policy,
  } = cast<BundleContentProps>(usePage().props);

  const [bundle, setBundle] = React.useState(initialBundle);
  React.useEffect(() => setBundle(initialBundle), [initialBundle]);
  const updateBundle = (update: Partial<Bundle> | ((bundle: Bundle) => void)) =>
    setBundle((prevBundle) => {
      if (typeof update === "function") {
        const updated = { ...prevBundle };
        update(updated);
        return updated;
      }
      return { ...prevBundle, ...update };
    });

  const [results, setResults] = React.useState<BundleProduct[]>([]);
  const [isLoading, setIsLoading] = React.useState(true);
  const [hasMoreResults, setHasMoreResults] = React.useState(true);
  const [query, setQuery] = React.useState("");

  const activeRequest = React.useRef<{ cancel: () => void } | null>();
  const loadSearchResults = async ({ query = "", loadMore = false, all = false } = {}) => {
    if (!hasMoreResults && loadMore) return results;
    setIsLoading(true);
    let newResults = results;
    try {
      activeRequest.current?.cancel();
      const request = searchProducts({ product_id: id, query, from: loadMore ? results.length + 1 : 0, all });
      activeRequest.current = request;
      newResults = loadMore ? [...results, ...(await request.response)] : await request.response;
      setResults(newResults);
      setHasMoreResults(!(all || newResults.length < RESULTS_PER_PAGE));
      activeRequest.current = null;
    } catch (e) {
      if (e instanceof AbortError) return newResults;
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
    return newResults;
  };

  useRunOnce(() => void loadSearchResults());
  useOnChange(
    useDebouncedCallback(() => void loadSearchResults({ query }), 300),
    [query],
  );

  const formRef = React.useRef<HTMLFormElement>(null);
  useOnScrollToBottom(
    formRef,
    () => {
      if (!activeRequest.current) void loadSearchResults({ query, loadMore: true });
    },
    30,
  );

  const [isSelecting, setIsSelecting] = React.useState(bundle.products.length > 0);

  // Provide context for components that might still need it
  const contextValue = React.useMemo(
    () => ({
      bundle,
      updateBundle,
      id,
      uniquePermalink: unique_permalink,
      currencyType: currency_type,
      thumbnail,
      salesCountForInventory: sales_count_for_inventory,
      ratings,
      taxonomies,
      profileSections: profile_sections,
      refundPolicies: refund_policies,
      productsCount: products_count,
      hasOutdatedPurchases: has_outdated_purchases,
      seller_refund_policy_enabled,
      seller_refund_policy,
    }),
    [bundle],
  );

  const preview = (
    <div>
      <header>
        <h1>Library</h1>
      </header>
      <section>
        <ProductCardGrid>
          {bundle.products.map((bundleProduct) => (
            <Card key={bundleProduct.id} product={bundleProduct} />
          ))}
        </ProductCardGrid>
      </section>
    </div>
  );

  return (
    <BundleEditContext.Provider value={contextValue}>
      <InertiaLayout
        currentTab="content"
        bundle={bundle}
        id={id}
        uniquePermalink={unique_permalink}
        onBundleChange={updateBundle}
        preview={preview}
      >
        <form onSubmit={(evt) => evt.preventDefault()} ref={formRef}>
          <section className="p-4! md:p-8!">
            {has_outdated_purchases ? <BundleContentUpdatedStatus /> : null}
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
                      checked={bundle.products.length === products_count}
                      disabled={isLoading}
                      onChange={(evt) =>
                        evt.target.checked
                          ? void loadSearchResults({ query, loadMore: true, all: true }).then((results) =>
                              updateBundle({ products: results }),
                            )
                          : updateBundle({ products: [] })
                      }
                    />
                    All products
                  </label>
                </header>
                {bundle.products.length > 0 ? (
                  <CartItemList aria-label="Bundle products">
                    {bundle.products.map((bundleProduct, idx) => (
                      <BundleProductItem
                        key={bundleProduct.id}
                        bundleProduct={bundleProduct}
                        updateBundleProduct={(update) =>
                          updateBundle({
                            products: [
                              ...bundle.products.slice(0, idx),
                              { ...bundleProduct, ...update },
                              ...bundle.products.slice(idx + 1),
                            ],
                          })
                        }
                        removeBundleProduct={() =>
                          updateBundle({ products: bundle.products.filter(({ id }) => id !== bundleProduct.id) })
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
                        const selected = bundle.products.some(({ id }) => id === bundleProduct.id);
                        return (
                          <BundleProductSelector
                            key={bundleProduct.id}
                            bundleProduct={bundleProduct}
                            selected={selected}
                            onToggle={() =>
                              updateBundle({
                                products: selected
                                  ? bundle.products.filter(({ id }) => id !== bundleProduct.id)
                                  : [...bundle.products, bundleProduct],
                              })
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
      </InertiaLayout>
    </BundleEditContext.Provider>
  );
}
