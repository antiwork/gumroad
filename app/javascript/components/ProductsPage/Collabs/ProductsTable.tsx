import * as React from "react";

import { getPagedProducts, ProductsParams, Product } from "$app/data/collabs";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Icon } from "$app/components/Icons";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { showAlert } from "$app/components/server-components/Alert";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useClientSortingTableDriver } from "$app/components/useSortingTableDriver";

type State = {
  entries: readonly Product[];
  pagination: PaginationProps;
  isLoading: boolean;
  query: string | null;
};

export const CollabsProductsTable = (props: { entries: Product[]; pagination: PaginationProps }) => {
  const [state, setState] = React.useState<State>({
    entries: props.entries,
    pagination: props.pagination,
    isLoading: false,
    query: null,
  });
  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);
  const tableRef = React.useRef<HTMLTableElement>(null);
  const userAgentInfo = useUserAgentInfo();

  const { entries: products, pagination, isLoading } = state;

  const loadProducts = asyncVoid(async ({ page, query }: ProductsParams) => {
    setState((prevState) => ({ ...prevState, isLoading: true }));
    try {
      activeRequest.current?.cancel();

      const request = getPagedProducts({
        page,
        query,
      });
      activeRequest.current = request;

      setState({
        ...(await request.response),
        isLoading: false,
        query,
      });
      activeRequest.current = null;
      tableRef.current?.scrollIntoView({ behavior: "smooth" });
    } catch (e) {
      if (e instanceof AbortError) return;
      assertResponseError(e);
      setState((prevState) => ({ ...prevState, isLoading: false }));
      showAlert(e.message, "error");
    }
  });

  const { items, thProps } = useClientSortingTableDriver<Product>(state.entries);

  return (
    <div className="flex flex-col gap-4">
      <table aria-live="polite" aria-busy={isLoading} ref={tableRef}>
        <caption>Products</caption>
        <thead>
          <tr>
            <th />
            <th {...thProps("name")} title="Sort by Name">
              Name
            </th>
            <th {...thProps("display_price_cents")} title="Sort by Price">
              Price
            </th>
            <th {...thProps("cut")} title="Sort by Cut">
              Cut
            </th>
            <th {...thProps("successful_sales_count")} title="Sort by Sales">
              Sales
            </th>
            <th {...thProps("revenue")} title="Sort by Revenue">
              Revenue
            </th>
          </tr>
        </thead>

        <tbody>
          {items.map((product) => (
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

              <td data-label="Price" style={{ whiteSpace: "nowrap" }}>
                {product.price_formatted}
              </td>

              <td data-label="Cut">{product.cut}%</td>

              <td data-label="Sales" style={{ whiteSpace: "nowrap" }}>
                <a href={Routes.customers_link_id_path(product.permalink)}>
                  {product.successful_sales_count.toLocaleString(userAgentInfo.locale)}
                </a>

                {product.remaining_for_sale_count ? (
                  <small>{product.remaining_for_sale_count.toLocaleString(userAgentInfo.locale)} remaining</small>
                ) : null}
              </td>

              <td data-label="Revenue" style={{ whiteSpace: "nowrap" }}>
                {formatPriceCentsWithCurrencySymbol("usd", product.revenue, { symbolFormat: "short" })}
              </td>
            </tr>
          ))}
        </tbody>

        <tfoot>
          <tr>
            <td colSpan={4}>Totals</td>
            <td>
              {products
                .reduce((sum, product) => sum + product.successful_sales_count, 0)
                .toLocaleString(userAgentInfo.locale)}
            </td>

            <td>
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
        <Pagination onChangePage={(page) => loadProducts({ page, query: state.query })} pagination={pagination} />
      ) : null}
    </div>
  );
};
