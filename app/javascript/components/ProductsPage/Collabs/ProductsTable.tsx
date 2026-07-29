import { router } from "@inertiajs/react";
import * as React from "react";

import { Product } from "$app/data/collabs";
import { classNames } from "$app/utils/classNames";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { Pagination, PaginationProps } from "$app/components/Pagination";
import { ProductIconCell } from "$app/components/ProductsPage/ProductIconCell";
import { StretchedLink } from "$app/components/ui/StretchedLink";
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

export const CollabsProductsTable = (props: { entries: Product[]; pagination: PaginationProps }) => {
  const [isLoading, setIsLoading] = React.useState(false);
  const tableRef = React.useRef<HTMLTableElement>(null);
  const userAgentInfo = useUserAgentInfo();
  const { items: products, thProps } = useClientSortingTableDriver(props.entries);

  const handlePageChange = (page: number) => {
    router.reload({
      data: { products_page: page },
      only: ["products_data"],
      onStart: () => setIsLoading(true),
      onFinish: () => {
        setIsLoading(false);
        tableRef.current?.scrollIntoView({ behavior: "smooth" });
      },
    });
  };

  return (
    <div className="flex flex-col gap-4">
      <Table ref={tableRef} aria-live="polite" className={classNames(isLoading && "pointer-events-none opacity-50")}>
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
          {products.map((product) => (
            <TableRow key={product.id}>
              <ProductIconCell
                href={product.can_edit ? product.edit_url : product.url}
                thumbnail={product.thumbnail?.url ?? null}
              />

              {/* The name cell is `relative` so StretchedLink can fill it, as in
                  ProductsPage/ProductsTable.tsx. Only the bold name text used to be clickable,
                  which is a small target, and sellers reported that clicking a row "does nothing"
                  when they had in fact tapped the dead space beside the name (gumroad-private#1469).
                  Safari doesn't support `position: relative` on <tr>, so the row itself can't be
                  the link. */}
              <TableCell hideLabel className="relative">
                <div>
                  <StretchedLink href={product.can_edit ? product.edit_url : product.url}>
                    {/* dir="auto" lets RTL product names render right-to-left (gumroad-private#1259). */}
                    <h4 className="relative font-bold" dir="auto">
                      {product.name}
                    </h4>
                  </StretchedLink>

                  <a href={product.url} title={product.url} target="_blank" rel="noreferrer" className="relative z-1">
                    <small className="block">{product.url_without_protocol}</small>
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
                  <small className="block">
                    {product.remaining_for_sale_count.toLocaleString(userAgentInfo.locale)} remaining
                  </small>
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

      {props.pagination.pages > 1 ? <Pagination onChangePage={handlePageChange} pagination={props.pagination} /> : null}
    </div>
  );
};
