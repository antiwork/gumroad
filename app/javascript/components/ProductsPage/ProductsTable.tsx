import { Link, router } from "@inertiajs/react";
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
      only: ["products_data", "has_products"],
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
      only: ["products_data", "has_products"],
      onStart: () => setIsLoading(true),
      onFinish: () => {
        setIsLoading(false);
        tableRef.current?.scrollIntoView({ behavior: "smooth" });
      },
    });
  };

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
            <TableHead />
          </TableRow>
        </TableHeader>

        <TableBody>
          {products.map((product) => (
            <TableRow key={product.id}>
              <ProductIconCell
                href={product.can_edit ? product.edit_url : product.url}
                thumbnail={product.thumbnail?.url ?? null}
              />
              {/* The name cell is `relative` so the product link inside it can stretch to fill the
                  whole cell (see the `absolute inset-0` overlay below). Before this, only the bold
                  name text itself was clickable, which is a small target — sellers reported that
                  clicking a product row "does nothing" when they had in fact tapped the dead space
                  beside the name (gumroad-private#1469). Making the entire cell clickable is as far
                  as we can widen it without nesting links: Safari doesn't support
                  `position: relative` on <tr>, so the row itself can't be the link, and the Sales
                  cell has its own link to the customers page. */}
              <TableCell hideLabel className="relative">
                <div>
                  {product.can_edit ? (
                    <Link href={product.edit_url} style={{ textDecoration: "none" }}>
                      {/* This empty overlay is what widens the hit area: it stretches the
                          surrounding link over the full cell, including the padding and the empty
                          space to the right of a short product name. It sits behind the two
                          positioned links below, so the storefront URL link still wins a tap on
                          its own text. */}
                      <span className="absolute inset-0" aria-hidden="true" />
                      {/* dir="auto" lets RTL product names (Hebrew, Arabic) render right-to-left
                          (gumroad-private#1259; same fix as the product page in #6190). */}
                      <h4 className="relative font-bold" dir="auto">
                        {product.name}
                      </h4>
                    </Link>
                  ) : (
                    <a href={product.url} title={product.url} target="_blank" rel="noreferrer">
                      <span className="absolute inset-0" aria-hidden="true" />
                      <h4 className="relative font-bold" dir="auto">
                        {product.name}
                      </h4>
                    </a>
                  )}

                  {/* A plain <a>, deliberately not an Inertia <Link>, because this one opens a new
                      tab. Inertia's Link always calls preventDefault() and does a client-side visit
                      when the click has no modifier key held: its shouldIntercept() helper looks only
                      at the tag name and at alt/ctrl/meta/shift, and never at target="_blank". So an
                      Inertia Link with target="_blank" silently navigates the current tab to the
                      storefront instead of opening a new one. The other three product tables
                      (memberships, and both collab tables) already use a plain <a> here for the same
                      reason; this one was the odd surface out. */}
                  <a href={product.url} title={product.url} target="_blank" rel="noreferrer" className="relative">
                    <small className="block">{product.url_without_protocol}</small>
                  </a>
                </div>
              </TableCell>

              <TableCell className="whitespace-nowrap">
                <Link href={Routes.customers_link_id_path(product.permalink)}>
                  {product.successful_sales_count.toLocaleString(locale)}
                </Link>

                {product.remaining_for_sale_count ? (
                  <small className="block">{product.remaining_for_sale_count.toLocaleString(locale)} remaining</small>
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
