import * as React from "react";

import { getPagedProducts, ProductsParams, Product } from "$app/data/collabs";
import { classNames } from "$app/utils/classNames";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Pagination, PaginationProps } from "$app/components/Pagination";
import { ProductIconCell } from "$app/components/ProductsPage/ProductIconCell";
import { showAlert } from "$app/components/server-components/Alert";
import {
  Table,
  TableBody,
  TableCaption,
  TableCell,
  TableFooter,
  TableHead,
  TableHeader,
  TableRow,
} from "$app/components/ui/Table";
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
      <Table aria-live="polite" className={classNames(isLoading && "pointer-events-none opacity-50")} ref={tableRef}>
        <TableCaption>Products</TableCaption>
        <TableHeader>
          <TableRow>
            <TableHead />
            <TableHead {...thProps("name")} className="lg:relative lg:-left-20">
              Name
            </TableHead>
            <TableHead {...thProps("display_price_cents")}>Price</TableHead>
            <TableHead {...thProps("cut")}>Cut</TableHead>
            <TableHead {...thProps("successful_sales_count")}>Sales</TableHead>
            <TableHead {...thProps("revenue")}>Revenue</TableHead>
          </TableRow>
        </TableHeader>

        <TableBody>
          {items.map((product) => (
            <TableRow key={product.id}>
              <ProductIconCell
                href={product.can_edit ? product.edit_url : product.url}
                thumbnail={product.thumbnail?.url ?? null}
              />

              <TableCell hideLabel>
                <div>
                  {/* Safari currently doesn't support position: relative on <tr>, so we can't make the whole row a link here */}
                  <a href={product.can_edit ? product.edit_url : product.url} style={{ textDecoration: "none" }}>
                    <h4 className="font-bold">{product.name}</h4>
                  </a>

                  <a href={product.url} title={product.url} target="_blank" rel="noreferrer">
                    <small>{product.url_without_protocol}</small>
                  </a>
                </div>
              </TableCell>

              <TableCell className="whitespace-nowrap">{product.price_formatted}</TableCell>

              <TableCell>{product.cut}%</TableCell>

              <TableCell className="whitespace-nowrap">
                <a href={Routes.customers_link_id_path(product.permalink)}>
                  {product.successful_sales_count.toLocaleString(userAgentInfo.locale)}
                </a>

                {product.remaining_for_sale_count ? (
                  <small>{product.remaining_for_sale_count.toLocaleString(userAgentInfo.locale)} remaining</small>
                ) : null}
              </TableCell>

              <TableCell className="whitespace-nowrap">
                {formatPriceCentsWithCurrencySymbol("usd", product.revenue, { symbolFormat: "short" })}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>

        <TableFooter>
          <TableRow>
            <TableCell colSpan={4}>Totals</TableCell>
            <TableCell label="Sales">
              {products
                .reduce((sum, product) => sum + product.successful_sales_count, 0)
                .toLocaleString(userAgentInfo.locale)}
            </TableCell>

            <TableCell label="Revenue">
              {formatPriceCentsWithCurrencySymbol(
                "usd",
                products.reduce((sum, product) => sum + product.revenue, 0),
                { symbolFormat: "short" },
              )}
            </TableCell>
          </TableRow>
        </TableFooter>
      </Table>

      {pagination.pages > 1 ? (
        <Pagination onChangePage={(page) => loadProducts({ page, query: state.query })} pagination={pagination} />
      ) : null}
    </div>
  );
};
