import { Link, router, useForm, usePage } from "@inertiajs/react";
import cx from "classnames";
import { parseISO } from "date-fns";
import * as React from "react";

import { type Affiliate, type AffiliateRequest, type AffiliateStatistics, getStatistics } from "$app/data/affiliates";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Popover } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { Skeleton } from "$app/components/Skeleton";
import { Card, CardContent } from "$app/components/ui/Card";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useLocalPagination } from "$app/components/useLocalPagination";
import { useUserAgentInfo } from "$app/components/UserAgent";
import useRouteLoading from "$app/components/useRouteLoading";
import { Sort, useClientSortingTableDriver, useSortingTableDriver } from "$app/components/useSortingTableDriver";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/affiliated.png";

type SortKey = "affiliate_user_name" | "products" | "fee_percent" | "volume_cents";

type Props = {
  affiliate_requests: AffiliateRequest[];
  affiliates: Affiliate[];
  pagination: PaginationProps;
  allow_approve_all_requests: boolean;
  affiliates_disabled_reason: string | null;
};

const AffiliatesNavigation = () => (
  <Tabs>
    <Tab asChild isSelected>
      <Link href={Routes.affiliates_path()}>Affiliates</Link>
    </Tab>
    <Tab asChild isSelected={false}>
      <Link href={Routes.onboarding_affiliates_path()}>Affiliate Signup Form</Link>
    </Tab>
  </Tabs>
);

const SearchBoxPopover = ({ initialQuery, onSearch }: { initialQuery: string; onSearch: (query: string) => void }) => {
  const [searchBoxOpen, setSearchBoxOpen] = React.useState(false);
  const [inputValue, setInputValue] = React.useState(initialQuery);
  const searchInputRef = React.useRef<HTMLInputElement | null>(null);
  const wasOpenedRef = React.useRef(false);

  React.useEffect(() => {
    if (searchBoxOpen) {
      searchInputRef.current?.focus();
      wasOpenedRef.current = true;
    }
  }, [searchBoxOpen]);

  React.useEffect(() => {
    setInputValue(initialQuery);
    if (wasOpenedRef.current && initialQuery.length > 0) {
      setSearchBoxOpen(true);
    }
  }, [initialQuery]);

  const handleChange = (evt: React.ChangeEvent<HTMLInputElement>) => {
    const value = evt.target.value;
    setInputValue(value);
    onSearch(value);
  };

  return (
    <Popover
      open={searchBoxOpen}
      onToggle={setSearchBoxOpen}
      aria-label="Search"
      trigger={
        <WithTooltip tip="Search" position="bottom">
          <div className="button">
            <Icon name="solid-search" />
          </div>
        </WithTooltip>
      }
    >
      <div className="input input-wrapper">
        <Icon name="solid-search" />
        <input
          ref={searchInputRef}
          value={inputValue}
          autoFocus
          type="text"
          placeholder="Search"
          aria-label="Search"
          onChange={handleChange}
        />
      </div>
    </Popover>
  );
};

const ApproveAllButton = () => {
  const { post, processing } = useForm({});
  return (
    <Button
      color="primary"
      onClick={() => post(Routes.approve_all_affiliate_requests_path(), { preserveScroll: true })}
      disabled={processing}
    >
      {processing ? "Approving..." : "Approve all"}
    </Button>
  );
};

const AffiliateRequestsTable = ({
  affiliateRequests,
  allowApproveAll,
}: {
  affiliateRequests: AffiliateRequest[];
  allowApproveAll: boolean;
}) => {
  const loggedInUser = useLoggedInUser();
  const userAgentInfo = useUserAgentInfo();
  const { items, thProps } = useClientSortingTableDriver(affiliateRequests, { key: "date", direction: "asc" });
  const { items: visibleItems, showMoreItems } = useLocalPagination(items, 20);
  const [processingId, setProcessingId] = React.useState<string | null>(null);

  const updateAffiliateRequest = (id: string, action: "approve" | "ignore") => {
    router.patch(
      Routes.affiliate_request_path(id),
      { affiliate_request: { action } },
      {
        preserveScroll: true,
        onStart: () => setProcessingId(id),
        onFinish: () => setProcessingId(null),
      },
    );
  };

  return (
    <>
      {visibleItems.length > 0 ? (
        <Table>
          <TableCaption>
            <div style={{ display: "flex", justifyContent: "space-between" }}>
              Requests
              {allowApproveAll ? <ApproveAllButton /> : null}
            </div>
          </TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead {...thProps("name")}>Name</TableHead>
              <TableHead {...thProps("promotion")}>Promotion</TableHead>
              <TableHead {...thProps("date")}>Date</TableHead>
              <TableHead />
            </TableRow>
          </TableHeader>

          <TableBody>
            {visibleItems.map((affiliateRequest) => (
              <TableRow key={affiliateRequest.id}>
                <TableCell>
                  {affiliateRequest.name}
                  <small>{affiliateRequest.email}</small>
                </TableCell>

                <TableCell>{affiliateRequest.promotion}</TableCell>

                <TableCell>{parseISO(affiliateRequest.date).toLocaleDateString(userAgentInfo.locale)}</TableCell>

                <TableCell>
                  <div className="flex flex-wrap gap-3 lg:justify-end">
                    <Button
                      disabled={!loggedInUser?.policies.direct_affiliate.update || processingId !== null}
                      onClick={() => updateAffiliateRequest(affiliateRequest.id, "ignore")}
                    >
                      {processingId === affiliateRequest.id ? "Ignoring..." : "Ignore"}
                    </Button>

                    <WithTooltip
                      tip={
                        affiliateRequest.state === "approved"
                          ? "You have approved this request but the affiliate hasn't created a Gumroad account yet"
                          : null
                      }
                      position="bottom"
                    >
                      <Button
                        color="primary"
                        onClick={() => updateAffiliateRequest(affiliateRequest.id, "approve")}
                        disabled={
                          !loggedInUser?.policies.direct_affiliate.update ||
                          affiliateRequest.state === "approved" ||
                          processingId !== null
                        }
                      >
                        {affiliateRequest.state === "approved"
                          ? "Approved"
                          : processingId === affiliateRequest.id
                            ? "Approving..."
                            : "Approve"}
                      </Button>
                    </WithTooltip>
                  </div>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      ) : (
        <Placeholder>No requests yet</Placeholder>
      )}

      {showMoreItems ? <Button onClick={showMoreItems}>Load more</Button> : null}
    </>
  );
};

const formattedSalesVolumeAmount = (amountCents: number) =>
  formatPriceCentsWithCurrencySymbol("usd", amountCents, { symbolFormat: "short" });

export default function AffiliatesIndex() {
  const props = usePage<Props>().props;
  const loggedInUser = useLoggedInUser();
  const isNavigating = useRouteLoading();

  const { affiliates, affiliate_requests, pagination, allow_approve_all_requests, affiliates_disabled_reason } = props;
  const [selectedAffiliate, setSelectedAffiliate] = React.useState<Affiliate | null>(null);

  const searchParams = new URLSearchParams(window.location.search);
  const searchQuery = searchParams.get("query") ?? "";

  const sortFromUrl = React.useMemo((): Sort<SortKey> | null => {
    const column = searchParams.get("column");
    const direction = searchParams.get("sort");
    const isSortKey = (value: string | null): value is SortKey =>
      value === "affiliate_user_name" || value === "products" || value === "fee_percent" || value === "volume_cents";
    const isDirection = (value: string | null): value is "asc" | "desc" => value === "asc" || value === "desc";
    if (isSortKey(column) && isDirection(direction)) {
      return { key: column, direction };
    }
    return null;
  }, [searchParams.get("column"), searchParams.get("sort")]);
  const [sort, setSort] = React.useState<Sort<SortKey> | null>(sortFromUrl);

  React.useEffect(() => {
    setSort(sortFromUrl);
  }, [sortFromUrl]);

  const onSearch = useDebouncedCallback((newQuery: string) => {
    const params = new URLSearchParams(window.location.search);
    if (newQuery.length > 0) {
      params.set("query", newQuery);
    } else {
      params.delete("query");
    }
    params.delete("page");
    const url = new URL(window.location.href);
    url.search = params.toString();
    router.get(url.toString());
  }, 500);

  const onChangePage = (newPage: number) => {
    const params = new URLSearchParams(window.location.search);
    params.set("page", newPage.toString());
    const url = new URL(window.location.href);
    url.search = params.toString();
    router.get(url.toString());
  };

  const onSetSort = (newSort: Sort<SortKey> | null) => {
    const params = new URLSearchParams(window.location.search);
    if (pagination.pages > 1) params.set("page", "1");
    if (newSort) {
      params.set("column", newSort.key);
      params.set("sort", newSort.direction);
    } else {
      params.delete("column");
      params.delete("sort");
    }
    setSort(newSort);
    const url = new URL(window.location.href);
    url.search = params.toString();
    router.get(url.toString());
  };
  const thProps = useSortingTableDriver<SortKey>(sort, onSetSort);

  const formatAffiliateBasisPoints = (basisPoints: number) =>
    (basisPoints / 100).toLocaleString([], { style: "percent" });

  const formattedFeePercentLabel = (affiliate: Affiliate) => {
    if (affiliate.apply_to_all_products) return formatAffiliateBasisPoints(affiliate.fee_percent);

    const productCommissions = affiliate.products.map((product) => product.fee_percent ?? 0);
    const minFeePercent = Math.min(...productCommissions);
    const maxFeePercent = Math.max(...productCommissions);
    return minFeePercent === maxFeePercent
      ? formatAffiliateBasisPoints(minFeePercent)
      : `${formatAffiliateBasisPoints(minFeePercent)} - ${formatAffiliateBasisPoints(maxFeePercent)}`;
  };

  const productName = (products: Affiliate["products"]) =>
    products.length === 1 ? (products[0]?.name ?? "") : `${products.length} products`;
  const productTooltipLabel = (products: Affiliate["products"]) =>
    products.map((product) => `${product.name} (${formatAffiliateBasisPoints(product.fee_percent ?? 0)})`).join(", ");

  const remove = (affiliateId: string) => {
    if (selectedAffiliate) setSelectedAffiliate(null);
    router.delete(Routes.affiliate_path(affiliateId));
  };

  const [affiliateStatistics, setAffiliateStatistics] = React.useState<Record<string, AffiliateStatistics>>({});
  const affiliateStatisticsRequests = React.useRef<Set<string>>(new Set());

  React.useEffect(() => {
    for (const { id } of affiliates) {
      if (affiliateStatisticsRequests.current.has(id)) continue;

      affiliateStatisticsRequests.current.add(id);
      getStatistics(id).then(
        (statistics) => setAffiliateStatistics((prev) => ({ ...prev, [id]: statistics })),
        (err: unknown) => {
          assertResponseError(err);
          showAlert(err instanceof Error ? err.message : String(err), "error");
          affiliateStatisticsRequests.current.delete(id);
        },
      );
    }
  }, [affiliates]);

  return (
    <div>
      <PageHeader
        title="Affiliates"
        actions={
          <>
            <SearchBoxPopover onSearch={onSearch} initialQuery={searchQuery} />
            <WithTooltip position="bottom" tip={affiliates_disabled_reason}>
              <NavigationButtonInertia
                href={Routes.new_affiliate_path()}
                color="accent"
                disabled={!loggedInUser?.policies.direct_affiliate.create || affiliates_disabled_reason !== null}
              >
                Add affiliate
              </NavigationButtonInertia>
            </WithTooltip>
          </>
        }
      >
        <AffiliatesNavigation />
      </PageHeader>
      <div className="p-4 lg:p-8" style={{ display: "grid", gap: "var(--spacer-7)" }}>
        {isNavigating && affiliates.length === 0 ? (
          <div style={{ justifySelf: "center" }}>
            <LoadingSpinner className="size-20" />
          </div>
        ) : (
          <>
            {!searchQuery && pagination.page === 1 ? (
              <AffiliateRequestsTable
                affiliateRequests={affiliate_requests}
                allowApproveAll={allow_approve_all_requests}
              />
            ) : null}
            {affiliates.length > 0 ? (
              <>
                <section className="flex flex-col gap-4">
                  <Table aria-live="polite" className={cx(isNavigating && "pointer-events-none opacity-50")}>
                    <TableCaption>
                      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                        Affiliates
                        <div className="text-base">
                          <WithTooltip tip="Export" position="top">
                            <a href={Routes.export_affiliates_path()} className="button primary" aria-label="Export">
                              <Icon name="download" />
                            </a>
                          </WithTooltip>
                        </div>
                      </div>
                    </TableCaption>
                    <TableHeader>
                      <TableRow>
                        <TableHead {...thProps("affiliate_user_name")}>Name</TableHead>
                        <TableHead {...thProps("products")}>Products</TableHead>
                        <TableHead {...thProps("fee_percent")}>Commission</TableHead>
                        <TableHead {...thProps("volume_cents")}>Sales</TableHead>
                        <TableHead />
                      </TableRow>
                    </TableHeader>

                    <TableBody>
                      {affiliates.map((affiliate) => {
                        const enabledProducts = affiliate.products;
                        const statistics = affiliateStatistics[affiliate.id];

                        return (
                          <TableRow
                            key={affiliate.id}
                            selected={affiliate.id === selectedAffiliate?.id}
                            onClick={() => setSelectedAffiliate(affiliate)}
                          >
                            <TableCell>{affiliate.affiliate_user_name}</TableCell>
                            <TableCell>
                              <WithTooltip
                                tip={enabledProducts.length <= 1 ? null : productTooltipLabel(enabledProducts)}
                              >
                                <a href={affiliate.product_referral_url} onClick={(e) => e.stopPropagation()}>
                                  {productName(enabledProducts)}
                                </a>
                              </WithTooltip>
                            </TableCell>
                            <TableCell>{formattedFeePercentLabel(affiliate)}</TableCell>
                            <TableCell aria-busy={!statistics}>
                              {statistics ? (
                                formattedSalesVolumeAmount(statistics.total_volume_cents)
                              ) : (
                                <Skeleton className="w-16" />
                              )}
                            </TableCell>
                            <TableCell onClick={(e) => e.stopPropagation()}>
                              <div className="flex flex-wrap gap-3 lg:justify-end">
                                <CopyToClipboard
                                  tooltipPosition="bottom"
                                  copyTooltip="Copy link"
                                  text={affiliate.product_referral_url}
                                >
                                  <Button>Copy link</Button>
                                </CopyToClipboard>

                                <NavigationButtonInertia
                                  href={Routes.edit_affiliate_path(affiliate.id)}
                                  aria-label="Edit"
                                  disabled={!loggedInUser?.policies.direct_affiliate.update || isNavigating}
                                >
                                  <Icon name="pencil" />
                                </NavigationButtonInertia>

                                <Button
                                  type="submit"
                                  color="danger"
                                  onClick={() => remove(affiliate.id)}
                                  aria-label="Delete"
                                  disabled={!loggedInUser?.policies.direct_affiliate.update || isNavigating}
                                >
                                  <Icon name="trash2" />
                                </Button>
                              </div>
                            </TableCell>
                          </TableRow>
                        );
                      })}
                    </TableBody>
                  </Table>
                  {pagination.pages > 1 ? <Pagination onChangePage={onChangePage} pagination={pagination} /> : null}
                </section>
                {selectedAffiliate ? (
                  <AffiliateDetails
                    selectedAffiliate={selectedAffiliate}
                    statistics={affiliateStatistics[selectedAffiliate.id]}
                    onClose={() => setSelectedAffiliate(null)}
                    onRemove={remove}
                    isNavigating={isNavigating}
                  />
                ) : null}
              </>
            ) : (
              <Placeholder>
                <PlaceholderImage src={placeholder} />
                <h2>No affiliates found</h2>
              </Placeholder>
            )}
          </>
        )}
      </div>
    </div>
  );
}

const AffiliateDetails = ({
  selectedAffiliate,
  statistics,
  onClose,
  onRemove,
  isNavigating,
}: {
  selectedAffiliate: Affiliate;
  statistics: AffiliateStatistics | undefined;
  onClose: () => void;
  onRemove: (id: string) => void;
  isNavigating: boolean;
}) => {
  const loggedInUser = useLoggedInUser();

  return (
    <Sheet open onOpenChange={onClose}>
      <SheetHeader>{selectedAffiliate.affiliate_user_name}</SheetHeader>
      {selectedAffiliate.products.map((product) => {
        const productStatistics = statistics?.products[product.id];

        return (
          <Card asChild key={product.id}>
            <section>
              <CardContent asChild>
                <h3>{product.name}</h3>
              </CardContent>
              {statistics ? (
                <>
                  <CardContent>
                    <h5 className="grow font-bold">Revenue</h5>
                    {formattedSalesVolumeAmount(productStatistics?.volume_cents ?? 0)}
                  </CardContent>
                  <CardContent>
                    <h5 className="grow font-bold">Sales</h5>
                    {productStatistics?.sales_count ?? 0}
                  </CardContent>
                </>
              ) : null}
              <CardContent>
                <h5 className="grow font-bold">Commission</h5>
                {((product.fee_percent ?? 0) / 100).toLocaleString([], { style: "percent" })}
              </CardContent>
              <CardContent>
                <CopyToClipboard tooltipPosition="bottom" copyTooltip="Copy link" text={product.referral_url}>
                  <Button>Copy link</Button>
                </CopyToClipboard>
              </CardContent>
            </section>
          </Card>
        );
      })}
      <section style={{ display: "grid", gap: "var(--spacer-4)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
        <NavigationButtonInertia
          href={Routes.edit_affiliate_path(selectedAffiliate.id)}
          aria-label="Edit"
          disabled={!loggedInUser?.policies.direct_affiliate.update || isNavigating}
        >
          Edit
        </NavigationButtonInertia>
        <Button
          color="danger"
          aria-label="Delete"
          onClick={() => onRemove(selectedAffiliate.id)}
          disabled={!loggedInUser?.policies.direct_affiliate.update || isNavigating}
        >
          Delete
        </Button>
      </section>
    </Sheet>
  );
};
