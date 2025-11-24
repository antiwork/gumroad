import * as React from "react";

import { getPagedMemberships, MembershipsParams, Membership } from "$app/data/collabs";
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
  entries: readonly Membership[];
  pagination: PaginationProps;
  isLoading: boolean;
  query: string | null;
};

export const CollabsMembershipsTable = (props: { entries: Membership[]; pagination: PaginationProps }) => {
  const [state, setState] = React.useState<State>({
    entries: props.entries,
    pagination: props.pagination,
    isLoading: false,
    query: null,
  });
  const { entries, pagination, isLoading } = state;
  const { items: memberships, thProps } = useClientSortingTableDriver<Membership>(entries);
  const { locale } = useUserAgentInfo();

  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);
  const loadMemberships = asyncVoid(async ({ query, page }: MembershipsParams) => {
    setState((prevState) => ({ ...prevState, isLoading: true }));
    try {
      activeRequest.current?.cancel();
      const request = getPagedMemberships({ page, query });
      activeRequest.current = request;

      setState({
        ...(await request.response),
        isLoading: false,
        query,
      });
      activeRequest.current = null;
    } catch (e) {
      if (e instanceof AbortError) return;
      assertResponseError(e);
      showAlert(e.message, "error");
      setState((prevState) => ({ ...prevState, isLoading: false }));
    }
  });

  return (
    <section className="flex flex-col gap-4">
      <Table aria-live="polite" className={classNames(isLoading && "pointer-events-none opacity-50")}>
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

            <TableCell>
              {memberships
                .reduce((sum, membership) => sum + membership.successful_sales_count, 0)
                .toLocaleString(locale)}
            </TableCell>

            <TableCell>
              {formatPriceCentsWithCurrencySymbol(
                "usd",
                memberships.reduce((sum, membership) => sum + membership.revenue, 0),
                { symbolFormat: "short" },
              )}
            </TableCell>
          </TableRow>
        </TableFooter>
      </Table>

      {pagination.pages > 1 ? (
        <Pagination onChangePage={(page) => loadMemberships({ query: state.query, page })} pagination={pagination} />
      ) : null}
    </section>
  );
};
