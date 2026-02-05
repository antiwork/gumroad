import { router } from "@inertiajs/react";
import * as React from "react";

import { Product, SortKey } from "$app/data/products";
import { classNames } from "$app/utils/classNames";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Tab } from "$app/components/ProductsLayout";
import ActionsPopover from "$app/components/ProductsPage/ActionsPopover";
import { ProductIconCell } from "$app/components/ProductsPage/ProductIconCell";
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
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { Sort, useSortingTableDriver } from "$app/components/useSortingTableDriver";

export const ProductsPageProductsTable = (props: {
  entries: Product[];
  pagination: PaginationProps;
  selectedTab: Tab;
  query: string | null;
  sort?: Sort<SortKey> | null | undefined;
  setEnableArchiveTab: ((enable: boolean) => void) | undefined;
}) => {
  const [isLoading, setIsLoading] = React.useState(false);
  const tableRef = React.useRef<HTMLTableElement>(null);
  const { locale } = useUserAgentInfo();
  const [sort, setSort] = React.useState<Sort<SortKey> | null>(props.sort ?? null);
  const products = props.entries;
  const pagination = props.pagination;

  const onSetSort = (newSort: Sort<SortKey> | null) => {
    router.reload({
      data: {
        products_sort_key: newSort?.key,
        products_sort_direction: newSort?.direction,
        products_page: undefined,
      },
      only: ["products_data"],
      onBefore: () => setSort(newSort),
      onStart: () => setIsLoading(true),
      onFinish: () => setIsLoading(false),
    });
  };

  const thProps = useSortingTableDriver<SortKey>(sort, onSetSort);

  const loadProducts = (page = 1) => {
    router.reload({
      data: {
        products_page: page,
        products_sort_key: sort?.key,
        products_sort_direction: sort?.direction,
        query: props.query || undefined,
      },
      only: ["products_data"],
      onStart: () => setIsLoading(true),
      onFinish: () => {
        setIsLoading(false);
        tableRef.current?.scrollIntoView({ behavior: "smooth" });
      },
    });
  };

  const debouncedLoadProducts = useDebouncedCallback(() => loadProducts(1), 300);

  React.useEffect(() => {
    if (props.query !== null) debouncedLoadProducts();
  }, [props.query]);

  const reloadProducts = () => loadProducts(pagination.page);

  if (!products.length) return null;

  return (
    <div className="flex flex-col gap-4">
      <Table ref={tableRef} aria-live="polite" className={classNames(isLoading && "pointer-events-none opacity-50")}>
        <TableCaption>Products</TableCaption>
        <TableHeader>
          <TableRow>
            <TableHead />
            <TableHead {...thProps("name")} title="Sort by Name" className="lg:relative lg:-left-20">
              Name
            </TableHead>
            <TableHead {...thProps("successful_sales_count")} title="Sort by Sales">
              Sales
            </TableHead>
            <TableHead {...thProps("revenue")} title="Sort by Revenue">
              Revenue
            </TableHead>
            <TableHead {...thProps("display_price_cents")} title="Sort by Price">
              Price
            </TableHead>
            <TableHead {...thProps("status")} title="Sort by Status">
              Status
            </TableHead>
          </TableRow>
        </TableHeader>

        <TableBody>
          {products.map((product) => (
            <TableRow key={product.id}>
              <ProductIconCell
                href={product.can_edit ? product.edit_url : product.url}
                thumbnail={product.thumbnail?.url ?? null}
              />
              <TableCell className="w-full" hideLabel>
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

              <TableCell className="whitespace-nowrap">
                <a href={Routes.customers_link_id_path(product.permalink)}>
                  {product.successful_sales_count.toLocaleString(locale)}
                </a>

                {product.remaining_for_sale_count ? (
                  <small>{product.remaining_for_sale_count.toLocaleString(locale)} remaining</small>
                ) : null}
              </TableCell>

              <TableCell className="whitespace-nowrap">
                {formatPriceCentsWithCurrencySymbol("usd", product.revenue, { symbolFormat: "short" })}
              </TableCell>

              <TableCell className="whitespace-nowrap">{product.price_formatted}</TableCell>

              <TableCell className="whitespace-nowrap">
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
              </TableCell>
              {product.can_duplicate || product.can_destroy ? (
                <TableCell>
                  <div className="flex flex-wrap gap-3 lg:justify-end">
                    <ActionsPopover
                      product={product}
                      onDuplicate={() => loadProducts()}
                      onDelete={() => reloadProducts()}
                      onArchive={() => {
                        props.setEnableArchiveTab?.(true);
                        reloadProducts();
                      }}
                      onUnarchive={(hasRemainingArchivedProducts) => {
                        props.setEnableArchiveTab?.(hasRemainingArchivedProducts);
                        if (!hasRemainingArchivedProducts) router.get(Routes.products_path());
                        else reloadProducts();
                      }}
                    />
                  </div>
                </TableCell>
              ) : null}
            </TableRow>
          ))}
        </TableBody>

        <TableFooter>
          <TableRow>
            <TableCell colSpan={2}>Totals</TableCell>
            <TableCell label="Sales" className="whitespace-nowrap">
              {products.reduce((sum, product) => sum + product.successful_sales_count, 0).toLocaleString(locale)}
            </TableCell>

            <TableCell colSpan={5} label="Revenue" className="whitespace-nowrap">
              {formatPriceCentsWithCurrencySymbol(
                "usd",
                products.reduce((sum, product) => sum + product.revenue, 0),
                { symbolFormat: "short" },
              )}
            </TableCell>
          </TableRow>
        </TableFooter>
      </Table>

      {pagination.pages > 1 ? <Pagination onChangePage={(page) => loadProducts(page)} pagination={pagination} /> : null}
    </div>
  );
};
