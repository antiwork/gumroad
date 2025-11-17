import * as React from "react";

import { getPagedMemberships, MembershipsParams, Membership } from "$app/data/collabs";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Icon } from "$app/components/Icons";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { showAlert } from "$app/components/server-components/Alert";
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
      <table aria-busy={isLoading}>
        <caption>Memberships</caption>
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
            <th {...thProps("successful_sales_count")} title="Sort by Members">
              Members
            </th>
            <th {...thProps("revenue")} title="Sort by Revenue">
              Revenue
            </th>
          </tr>
        </thead>

        <tbody>
          {memberships.map((membership) => (
            <tr key={membership.id}>
              <td className="icon-cell">
                {membership.thumbnail ? (
                  <a href={membership.can_edit ? membership.edit_url : membership.url}>
                    <img alt={membership.name} src={membership.thumbnail.url} />
                  </a>
                ) : (
                  <Icon name="card-image-fill" />
                )}
              </td>

              <td>
                {/* Safari currently doesn't support position: relative on <tr>, so we can't use stretched-link here */}
                <a href={membership.can_edit ? membership.edit_url : membership.url} style={{ textDecoration: "none" }}>
                  <h4>{membership.name}</h4>
                </a>
                <a href={membership.url} title={membership.url} target="_blank" rel="noreferrer">
                  <small>{membership.url_without_protocol}</small>
                </a>
              </td>

              <td data-label="Price">{membership.price_formatted}</td>

              <td data-label="Cut">{membership.cut}%</td>

              <td data-label="Members">
                {membership.successful_sales_count.toLocaleString(locale)}

                {membership.remaining_for_sale_count ? (
                  <small>{membership.remaining_for_sale_count.toLocaleString(locale)} remaining</small>
                ) : null}
              </td>

              <td data-label="Revenue">
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
              </td>
            </tr>
          ))}
        </tbody>

        <tfoot>
          <tr>
            <td colSpan={4}>Totals</td>

            <td>
              {memberships
                .reduce((sum, membership) => sum + membership.successful_sales_count, 0)
                .toLocaleString(locale)}
            </td>

            <td>
              {formatPriceCentsWithCurrencySymbol(
                "usd",
                memberships.reduce((sum, membership) => sum + membership.revenue, 0),
                { symbolFormat: "short" },
              )}
            </td>
          </tr>
        </tfoot>
      </table>

      {pagination.pages > 1 ? (
        <Pagination onChangePage={(page) => loadMemberships({ query: state.query, page })} pagination={pagination} />
      ) : null}
    </section>
  );
};
