import * as React from "react";

import { getPagedProducts, Product, SortKey } from "$app/data/products";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Icon } from "$app/components/Icons";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Tab } from "$app/components/ProductsLayout";
import ActionsPopover from "$app/components/ProductsPage/ActionsPopover";
import { showAlert } from "$app/components/server-components/Alert";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { Sort, useSortingTableDriver } from "$app/components/useSortingTableDriver";

type State = {
  entries: readonly Product[];
  pagination: PaginationProps;
  isLoading: boolean;
};

export const ProductsPageProductsTable = (props: {
  entries: Product[];
  pagination: PaginationProps;
  selectedTab: Tab;
  query: string | null;
  setEnableArchiveTab: ((enable: boolean) => void) | undefined;
}) => {
  const [{ entries: products, pagination, isLoading }, setState] = React.useState<State>({
    entries: props.entries,
    pagination: props.pagination,
    isLoading: false,
  });
  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);
  const tableRef = React.useRef<HTMLTableElement>(null);
  const { locale } = useUserAgentInfo();

  const [sort, setSort] = React.useState<Sort<SortKey> | null>(null);
  const thProps = useSortingTableDriver<SortKey>(sort, setSort);

  React.useEffect(() => {
    if (sort) void loadProducts(1);
  }, [sort]);

  const loadProducts = async (page: number) => {
    setState((prevState) => ({ ...prevState, isLoading: true }));
    try {
      activeRequest.current?.cancel();

      const request = getPagedProducts({
        page,
        query: props.query,
        sort,
        forArchivedProducts: props.selectedTab === "archived",
      });
      activeRequest.current = request;

      const response = await request.response;
      setState((prevState) => ({
        ...prevState,
        ...response,
        isLoading: false,
      }));
      activeRequest.current = null;
      tableRef.current?.scrollIntoView({ behavior: "smooth" });
    } catch (e) {
      if (e instanceof AbortError) return;
      assertResponseError(e);
      setState((prevState) => ({ ...prevState, isLoading: false }));
      showAlert(e.message, "error");
    }
  };
  const debouncedLoadProducts = useDebouncedCallback(() => void loadProducts(1), 300);

  React.useEffect(() => {
    if (props.query !== null) debouncedLoadProducts();
  }, [props.query]);

  const reloadProducts = () => loadProducts(pagination.page);

  if (!products.length) return null;

  return (
    <div className="paragraphs">
      <table aria-live="polite" aria-busy={isLoading} ref={tableRef}>
        <caption>Products</caption>
        <thead>
          <tr>
            <th />
            <th {...thProps("name")} title="Sort by Name">
              Name
            </th>
            <th {...thProps("successful_sales_count")} title="Sort by Sales">
              Sales
            </th>
            <th {...thProps("revenue")} title="Sort by Revenue">
              Revenue
            </th>
            <th {...thProps("display_price_cents")} title="Sort by Price">
              Price
            </th>
            <th {...thProps("status")} title="Sort by Status">
              Status
            </th>
          </tr>
        </thead>

        <tbody>
          {products.map((product) => (
            <tr key={product.id}>
              <td className="icon-cell">
                {product.thumbnail ? (
                  <a href={product.can_edit ? product.edit_url : product.url}>
                    <img alt={product.name} src={product.thumbnail.url} />
                  </a>
                ) : (
                  <Icon name="card-image-fill" />
                )}
              </td>
              <td>
                <div>
                  {/* Safari currently doesn't support position: relative on <tr>, so we can't use stretched-link here */}
                  <a href={product.can_edit ? product.edit_url : product.url} style={{ textDecoration: "none" }}>
                    <h4>{product.name}</h4>
                  </a>

                  <a href={product.url} title={product.url} target="_blank" rel="noreferrer">
                    <small>{product.url_without_protocol}</small>
                  </a>
                </div>
              </td>

              <td data-label="Sales" style={{ whiteSpace: "nowrap" }}>
                <a href={Routes.customers_link_id_path(product.permalink)}>
                  {product.successful_sales_count.toLocaleString(locale)}
                </a>

                {product.remaining_for_sale_count ? (
                  <small>{product.remaining_for_sale_count.toLocaleString(locale)} remaining</small>
                ) : null}
              </td>

              <td data-label="Revenue" style={{ whiteSpace: "nowrap" }}>
                {formatPriceCentsWithCurrencySymbol("usd", product.revenue, { symbolFormat: "short" })}
              </td>

              <td data-label="Price" style={{ whiteSpace: "nowrap" }}>
                {product.price_formatted}
              </td>

              <td data-label="Status" style={{ whiteSpace: "nowrap" }}>
                {(() => {
                  switch (product.status) {
                    case "unpublished":
                      return <>Unpublished</>;
                    case "preorder":
                      return <>Pre-order</>;
                    case "published":
                      return <>Published</>;
                  }
                })()}
              </td>
              {product.can_duplicate || product.can_destroy ? (
                <td>
                  <ActionsPopover
                    product={product}
                    onDuplicate={() => void loadProducts(1)}
                    onDelete={() => void reloadProducts()}
                    onArchive={() => {
                      props.setEnableArchiveTab?.(true);
                      void reloadProducts();
                    }}
                    onUnarchive={(hasRemainingArchivedProducts) => {
                      props.setEnableArchiveTab?.(hasRemainingArchivedProducts);
                      if (!hasRemainingArchivedProducts) window.location.href = Routes.products_path();
                      else void reloadProducts();
                    }}
                  />
                </td>
              ) : null}
            </tr>
          ))}
        </tbody>

        <tfoot>
          <tr>
            <td colSpan={2}>Totals</td>
            <td>{products.reduce((sum, product) => sum + product.successful_sales_count, 0).toLocaleString(locale)}</td>

            <td colSpan={5}>
              {formatPriceCentsWithCurrencySymbol(
                "usd",
                products.reduce((sum, product) => sum + product.revenue, 0),
                { symbolFormat: "short" },
              )}
            </td>
          </tr>
        </tfoot>
      </table>

      {pagination.pages > 1 ? (
        <Pagination onChangePage={(page) => void loadProducts(page)} pagination={pagination} />
      ) : null}
    </div>
  );
};
