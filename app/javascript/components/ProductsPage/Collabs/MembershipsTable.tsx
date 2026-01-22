import { router } from "@inertiajs/react";
import * as React from "react";

import { Membership } from "$app/data/collabs";
import { classNames } from "$app/utils/classNames";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { Pagination, PaginationProps } from "$app/components/Pagination";
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
import { useClientSortingTableDriver } from "$app/components/useSortingTableDriver";

export const CollabsMembershipsTable = (props: { entries: Membership[]; pagination: PaginationProps }) => {
  const [isLoading, setIsLoading] = React.useState(false);
  const tableRef = React.useRef<HTMLTableElement>(null);
  const { locale } = useUserAgentInfo();
  const { items: memberships, thProps } = useClientSortingTableDriver(props.entries);

  const handlePageChange = (page: number) => {
    router.reload({
      data: { memberships_page: page },
      only: ["memberships_data"],
      onStart: () => setIsLoading(true),
      onFinish: () => {
        setIsLoading(false);
        tableRef.current?.scrollIntoView({ behavior: "smooth" });
      },
    });
  };

  return (
    <section className="flex flex-col gap-4">
      <Table ref={tableRef} aria-live="polite" className={classNames(isLoading && "pointer-events-none opacity-50")}>
        <TableCaption>Memberships</TableCaption>
        <TableHeader>
          <TableRow>
            <TableHead />
            <TableHead {...thProps("name")} title="Sort by Name">
              Name
            </TableHead>

            <TableHead {...thProps("display_price_cents")} title="Sort by Price">
              Price
            </TableHead>
            <TableHead {...thProps("cut")} title="Sort by Cut">
              Cut
            </TableHead>
            <TableHead {...thProps("successful_sales_count")} title="Sort by Members">
              Members
            </TableHead>
            <TableHead {...thProps("revenue")} title="Sort by Revenue">
              Revenue
            </TableHead>
          </TableRow>
        </TableHeader>

        <TableBody>
          {memberships.map((membership) => (
            <TableRow key={membership.id}>
              <ProductIconCell
                href={membership.can_edit ? membership.edit_url : membership.url}
                thumbnail={membership.thumbnail?.url ?? null}
              />

              <TableCell hideLabel>
                {/* Safari currently doesn't support position: relative on <tr>, so we can't make the whole row a link here */}
                <a href={membership.can_edit ? membership.edit_url : membership.url} style={{ textDecoration: "none" }}>
                  <h4 className="font-bold">{membership.name}</h4>
                </a>
                <a href={membership.url} title={membership.url} target="_blank" rel="noreferrer">
                  <small>{membership.url_without_protocol}</small>
                </a>
              </TableCell>

              <TableCell>{membership.price_formatted}</TableCell>

              <TableCell>{membership.cut}%</TableCell>

              <TableCell>
                {membership.successful_sales_count.toLocaleString(locale)}

                {membership.remaining_for_sale_count ? (
                  <small>{membership.remaining_for_sale_count.toLocaleString(locale)} remaining</small>
                ) : null}
              </TableCell>

              <TableCell>
                {formatPriceCentsWithCurrencySymbol("usd", membership.revenue, { symbolFormat: "short" })}

                <small>
                  {membership.has_duration
                    ? `Including pending payments: ${formatPriceCentsWithCurrencySymbol(
                        "usd",
                        membership.revenue_pending * (membership.cut / 100.0),
                        {
                          symbolFormat: "short",
                        },
                      )}`
                    : `${formatPriceCentsWithCurrencySymbol(
                        "usd",
                        membership.monthly_recurring_revenue * (membership.cut / 100.0),
                        {
                          symbolFormat: "short",
                        },
                      )} /mo`}
                </small>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>

        <TableFooter>
          <TableRow>
            <TableCell colSpan={4}>Totals</TableCell>

            <TableCell label="Members">
              {memberships
                .reduce((sum, membership) => sum + membership.successful_sales_count, 0)
                .toLocaleString(locale)}
            </TableCell>

            <TableCell label="Revenue">
              {formatPriceCentsWithCurrencySymbol(
                "usd",
                memberships.reduce((sum, membership) => sum + membership.revenue, 0),
                { symbolFormat: "short" },
              )}
            </TableCell>
          </TableRow>
        </TableFooter>
      </Table>

      {props.pagination.pages > 1 ? <Pagination onChangePage={handlePageChange} pagination={props.pagination} /> : null}
    </section>
  );
};
