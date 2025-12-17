import { router } from "@inertiajs/react";
import * as React from "react";

import { getPagedMemberships, Membership, SortKey } from "$app/data/products";
import { classNames } from "$app/utils/classNames";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Tab } from "$app/components/ProductsLayout";
import ActionsPopover from "$app/components/ProductsPage/ActionsPopover";
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
    <section className="flex flex-col gap-4">
      <Table aria-live="polite" className={classNames(isLoading && "pointer-events-none opacity-50")}>
        <TableCaption>Memberships</TableCaption>
        <TableHeader>
          <TableRow>
            <TableHead />
            <TableHead {...thProps("name")} title="Sort by Name" className="lg:relative lg:-left-20">
              Name
            </TableHead>
            <TableHead {...thProps("successful_sales_count")} title="Sort by Members">
              Members
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

              <TableCell className="whitespace-nowrap">
                {membership.successful_sales_count.toLocaleString(userAgentInfo.locale)}

                {membership.remaining_for_sale_count ? (
                  <small>{membership.remaining_for_sale_count.toLocaleString(userAgentInfo.locale)} remaining</small>
                ) : null}
              </TableCell>

              <TableCell className="whitespace-nowrap">
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
              </TableCell>

              <TableCell className="whitespace-nowrap">{membership.price_formatted}</TableCell>

              <TableCell className="whitespace-nowrap">
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
              </TableCell>
              {membership.can_duplicate || membership.can_destroy ? (
                <TableCell>
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
                      if (!hasRemainingArchivedProducts) router.get(Routes.products_path());
                      else void reloadMemberships();
                    }}
                  />
                </TableCell>
              ) : null}
            </TableRow>
          ))}
        </TableBody>

        <TableFooter>
          <TableRow>
            <TableCell colSpan={2}>Totals</TableCell>

            <TableCell label="Members" className="whitespace-nowrap">
              {memberships
                .reduce((sum, membership) => sum + membership.successful_sales_count, 0)
                .toLocaleString(userAgentInfo.locale)}
            </TableCell>

            <TableCell colSpan={4} label="Revenue" className="whitespace-nowrap">
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
        <Pagination onChangePage={(page) => void loadMemberships(page)} pagination={pagination} />
      ) : null}
    </section>
  );
};
