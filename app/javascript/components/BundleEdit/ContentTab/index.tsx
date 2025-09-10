import * as React from "react";

import { searchProducts } from "$app/data/bundle";
import { AbortError, assertResponseError } from "$app/utils/request";

import { BundleContentUpdatedStatus } from "$app/components/BundleEdit/ContentTab/BundleContentUpdatedStatus";
import { BundleProductItem } from "$app/components/BundleEdit/ContentTab/BundleProductItem";
import { BundleProductSelector } from "$app/components/BundleEdit/ContentTab/BundleProductSelector";
import { Layout } from "$app/components/BundleEdit/Layout";
import { BundleProduct, useBundleEditContext } from "$app/components/BundleEdit/state";
import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Card } from "$app/components/Product/Card";
import { Progress } from "$app/components/Progress";
import { showAlert } from "$app/components/server-components/Alert";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";
import { useOnScrollToBottom } from "$app/components/useOnScrollToBottom";
import { useRunOnce } from "$app/components/useRunOnce";

const RESULTS_PER_PAGE = 10;
export const ContentTab = () => {
  const { bundle, updateBundle, id, productsCount, hasOutdatedPurchases } = useBundleEditContext();
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

  return (
    <Layout
      preview={
        <div>
          <header>
            <h1>Library</h1>
          </header>
          <section>
            <div className="product-card-grid">
              {bundle.products.map((bundleProduct) => (
                <Card key={bundleProduct.id} product={bundleProduct} />
              ))}
            </div>
          </section>
        </div>
      }
    >
      <form onSubmit={(evt) => evt.preventDefault()} ref={formRef}>
        <section className="!p-4 md:!p-8">
          {hasOutdatedPurchases ? <BundleContentUpdatedStatus /> : null}
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
                    checked={bundle.products.length === productsCount}
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
                <div className="cart" role="list" aria-label="Bundle products">
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
                </div>
              ) : null}
              <div className="card" aria-label="Product selector">
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
                    <Progress width="1em" />
                  </div>
                ) : results.length > 0 ? (
                  <div className="cart" role="list">
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
                  </div>
                ) : (
                  <div style={{ justifySelf: "center" }}>No products found</div>
                )}
              </div>
            </>
          ) : (
            <section className="placeholder">
              <h2>Select products</h2>
              <p>Choose the products you want to include in your bundle</p>
              <Button color="primary" onClick={() => setIsSelecting(true)}>
                <Icon name="plus" />
                Add products
              </Button>
            </section>
          )}
        </section>
      </form>
    </Layout>
  );
};
