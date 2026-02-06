import { router } from "@inertiajs/react";
import * as React from "react";

import { Membership, SortKey } from "$app/data/products";
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
import { useOnChange } from "$app/components/useOnChange";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { Sort, useSortingTableDriver } from "$app/components/useSortingTableDriver";

export const ProductsPageMembershipsTable = (props: {
  entries: Membership[];
  pagination: PaginationProps;
  selectedTab: Tab;
  query: string | null;
  sort?: Sort<SortKey> | null | undefined;
  setEnableArchiveTab: ((enable: boolean) => void) | undefined;
}) => {
  const [isLoading, setIsLoading] = React.useState(false);
  const tableRef = React.useRef<HTMLTableElement>(null);
  const userAgentInfo = useUserAgentInfo();
  const [sort, setSort] = React.useState<Sort<SortKey> | null>(props.sort ?? null);
  const memberships = props.entries;
  const pagination = props.pagination;

  const onSetSort = (newSort: Sort<SortKey> | null) => {
    router.reload({
      data: {
        memberships_sort_key: newSort?.key,
        memberships_sort_direction: newSort?.direction,
        memberships_page: undefined,
      },
      only: ["memberships_data"],
      onBefore: () => setSort(newSort),
      onStart: () => setIsLoading(true),
      onFinish: () => setIsLoading(false),
    });
  };

  const thProps = useSortingTableDriver<SortKey>(sort, onSetSort);

  const loadMemberships = (page = 1) => {
    router.reload({
      data: {
        memberships_page: page,
        memberships_sort_key: sort?.key,
        memberships_sort_direction: sort?.direction,
        query: props.query || undefined,
      },
      only: ["memberships_data"],
      onStart: () => setIsLoading(true),
      onFinish: () => {
        setIsLoading(false);
        tableRef.current?.scrollIntoView({ behavior: "smooth" });
      },
    });
  };

  const debouncedLoadMemberships = useDebouncedCallback(() => loadMemberships(1), 300);

  useOnChange(() => {
    if (props.query !== null) debouncedLoadMemberships();
  }, [props.query]);

  const reloadMemberships = () => loadMemberships(pagination.page);

  if (!memberships.length) return null;

  return (
    <section className="flex flex-col gap-4">
      <Table ref={tableRef} aria-live="polite" className={classNames(isLoading && "pointer-events-none opacity-50")}>
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
                    onDuplicate={() => loadMemberships()}
                    onDelete={() => reloadMemberships()}
                    onArchive={() => {
                      props.setEnableArchiveTab?.(true);
                      reloadMemberships();
                    }}
                    onUnarchive={(hasRemainingArchivedProducts) => {
                      props.setEnableArchiveTab?.(hasRemainingArchivedProducts);
                      if (!hasRemainingArchivedProducts) router.get(Routes.products_path());
                      else reloadMemberships();
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
        <Pagination onChangePage={(page) => loadMemberships(page)} pagination={pagination} />
      ) : null}
    </section>
  );
};
