import * as React from "react";

import { getPagedMemberships, Membership, SortKey } from "$app/data/products";
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
  entries: readonly Membership[];
  pagination: PaginationProps;
  isLoading: boolean;
};

export const ProductsPageMembershipsTable = (props: {
  entries: Membership[];
  pagination: PaginationProps;
  selectedTab: Tab;
  query: string | null;
  setEnableArchiveTab: ((enable: boolean) => void) | undefined;
}) => {
  const [{ entries: memberships, pagination, isLoading }, setState] = React.useState<State>({
    entries: props.entries,
    pagination: props.pagination,
    isLoading: false,
  });

  const userAgentInfo = useUserAgentInfo();

  const [sort, setSort] = React.useState<Sort<SortKey> | null>(null);
  const thProps = useSortingTableDriver<SortKey>(sort, setSort);

  React.useEffect(() => {
    if (sort) void loadMemberships(1);
  }, [sort]);

  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);
  const loadMemberships = async (page: number) => {
    setState((prevState) => ({ ...prevState, isLoading: true }));
    try {
      activeRequest.current?.cancel();
      const request = getPagedMemberships({
        forArchivedMemberships: props.selectedTab === "archived",
        page,
        query: props.query,
        sort,
      });
      activeRequest.current = request;

      const response = await request.response;

      setState((prevState) => ({
        ...prevState,
        ...response,
        isLoading: false,
      }));
      activeRequest.current = null;
    } catch (e) {
      if (e instanceof AbortError) return;
      assertResponseError(e);
      showAlert(e.message, "error");
      setState((prevState) => ({ ...prevState, isLoading: false }));
    }
  };
  const debouncedLoadMemberships = useDebouncedCallback(() => void loadMemberships(1), 300);

  React.useEffect(() => {
    if (props.query !== null) debouncedLoadMemberships();
  }, [props.query]);

  const reloadMemberships = () => loadMemberships(pagination.page);

  if (!memberships.length) return null;

  return (
    <section className="paragraphs">
      <table aria-busy={isLoading}>
        <caption>Memberships</caption>
        <thead>
          <tr>
            <th />
            <th {...thProps("name")} title="Sort by Name" className="lg:relative lg:-left-20">
              Name
            </th>
            <th {...thProps("successful_sales_count")} title="Sort by Members" className="lg:px-8">
              Members
            </th>
            <th {...thProps("revenue")} title="Sort by Revenue" className="lg:px-8">
              Revenue
            </th>
            <th {...thProps("display_price_cents")} title="Sort by Price" className="lg:px-8">
              Price
            </th>
            <th {...thProps("status")} title="Sort by Status" className="lg:px-8">
              Status
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
              <td className="w-full">
                {/* Safari currently doesn't support position: relative on <tr>, so we can't use stretched-link here */}
                <a href={membership.can_edit ? membership.edit_url : membership.url} style={{ textDecoration: "none" }}>
                  <h4>{membership.name}</h4>
                </a>
                <a href={membership.url} title={membership.url} target="_blank" rel="noreferrer">
                  <small>{membership.url_without_protocol}</small>
                </a>
              </td>

              <td data-label="Members" className="whitespace-nowrap lg:px-8">
                {membership.successful_sales_count.toLocaleString(userAgentInfo.locale)}

                {membership.remaining_for_sale_count ? (
                  <small>{membership.remaining_for_sale_count.toLocaleString(userAgentInfo.locale)} remaining</small>
                ) : null}
              </td>

              <td data-label="Revenue" className="whitespace-nowrap lg:px-8">
                {formatPriceCentsWithCurrencySymbol("usd", membership.revenue, { symbolFormat: "short" })}

                <small>
                  {membership.has_duration
                    ? `Including pending payments: ${formatPriceCentsWithCurrencySymbol(
                        "usd",
                        membership.revenue_pending,
                        {
                          symbolFormat: "short",
                        },
                      )}`
                    : `${formatPriceCentsWithCurrencySymbol("usd", membership.monthly_recurring_revenue, {
                        symbolFormat: "short",
                      })} /mo`}
                </small>
              </td>

              <td data-label="Price" className="whitespace-nowrap lg:px-8">
                {membership.price_formatted}
              </td>

              <td data-label="Status" className="whitespace-nowrap lg:px-8">
                {(() => {
                  switch (membership.status) {
                    case "unpublished":
                      return <>Unpublished</>;
                    case "preorder":
                      return <>Pre-order</>;
                    case "published":
                      return <>Published</>;
                  }
                })()}
              </td>
              {membership.can_duplicate || membership.can_destroy ? (
                <td className="lg:px-8">
                  <ActionsPopover
                    product={membership}
                    onDuplicate={() => void loadMemberships(1)}
                    onDelete={() => void reloadMemberships()}
                    onArchive={() => {
                      props.setEnableArchiveTab?.(true);
                      void reloadMemberships();
                    }}
                    onUnarchive={(hasRemainingArchivedProducts) => {
                      props.setEnableArchiveTab?.(hasRemainingArchivedProducts);
                      if (!hasRemainingArchivedProducts) window.location.href = Routes.products_path();
                      else void reloadMemberships();
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

            <td className="whitespace-nowrap lg:px-8">
              {memberships
                .reduce((sum, membership) => sum + membership.successful_sales_count, 0)
                .toLocaleString(userAgentInfo.locale)}
            </td>

            <td colSpan={4} className="whitespace-nowrap lg:px-8">
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
        <Pagination onChangePage={(page) => void loadMemberships(page)} pagination={pagination} />
      ) : null}
    </section>
  );
};
