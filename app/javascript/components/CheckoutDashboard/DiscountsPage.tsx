import cx from "classnames";
import * as React from "react";
import { GroupBase, SelectInstance } from "react-select";
import { is } from "ts-safe-cast";

import {
  OfferCodeStatistics,
  createDiscount,
  deleteDiscount,
  getPagedDiscounts,
  getStatistics,
  updateDiscount,
} from "$app/data/offer_code";
import { CurrencyCode, formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { AbortError, assertResponseError } from "$app/utils/request";
import { writeQueryParams } from "$app/utils/url";

import { Button } from "$app/components/Button";
import { DiscountInput, InputtedDiscount } from "$app/components/CheckoutDashboard/DiscountInput";
import { Layout, Page } from "$app/components/CheckoutDashboard/Layout";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { DateInput } from "$app/components/DateInput";
import { Details } from "$app/components/Details";
import { Dropdown } from "$app/components/Dropdown";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NumberInput } from "$app/components/NumberInput";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { PriceInput } from "$app/components/PriceInput";
import { Search } from "$app/components/Search";
import { Select, Option } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { Skeleton } from "$app/components/Skeleton";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Pill } from "$app/components/ui/Pill";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useSortingTableDriver, Sort } from "$app/components/useSortingTableDriver";

import blackFridayIllustration from "$assets/images/illustrations/black_friday.svg";
import placeholder from "$assets/images/placeholders/discounts.png";

type Product = {
  id: string;
  name: string;
  currency_type: CurrencyCode;
  url: string;
  is_tiered_membership: boolean;
  is_recurring_billing: boolean;
  archived: boolean;
};

export type Duration = 1;

export type OfferCode = {
  id: string;
  can_update: boolean;
  name: string;
  code: string;
  products: Product[] | null;
  discount: { type: "cents" | "percent"; value: number };
  limit: number | null;
  currency_type: CurrencyCode;
  valid_at: string | null;
  expires_at: string | null;
  duration_in_billing_cycles: Duration | null;
  minimum_quantity: number | null;
  minimum_amount_cents: number | null;
};

export type SortKey = "name" | "revenue" | "uses" | "term";
export type QueryParams = {
  sort: Sort<SortKey> | null;
  query: string | null;
  page: number | null;
};

const formatProducts = (offerCode: OfferCode) => {
  if (!offerCode.products) return "all products";
  const products = offerCode.products
    .slice(0, 2)
    .map(({ name }) => name)
    .join(", ");
  return offerCode.products.length > 2
    ? `${products}, and ${offerCode.products.length - 2} ${offerCode.products.length - 2 === 1 ? "other" : "others"}`
    : products;
};
const formatAmount = (offerCode: OfferCode) =>
  offerCode.discount.type === "cents"
    ? formatPriceCentsWithCurrencySymbol(offerCode.currency_type, offerCode.discount.value, {
        symbolFormat: "short",
      })
    : `${offerCode.discount.value}%`;
const formatRevenue = (revenue: number) => formatPriceCentsWithCurrencySymbol("usd", revenue, { symbolFormat: "long" });
const formatUses = (uses: number, limit: number | null) => `${uses}/${limit ?? "∞"}`;

const extractParams = (rawParams: URLSearchParams): QueryParams => {
  const column = rawParams.get("column");
  let sort: Sort<SortKey> | null = null;
  switch (column) {
    case "name":
    case "revenue":
    case "uses":
    case "term":
      sort = {
        direction: rawParams.get("sort") === "desc" ? "desc" : "asc",
        key: column,
      };
      break;
    default:
      break;
  }
  const query = rawParams.get("query");
  const pageStr = rawParams.get("page");
  const page = pageStr ? parseInt(pageStr, 10) : 1;
  return {
    query: query ? decodeURIComponent(query) : "",
    sort,
    page,
  };
};

const year = new Date().getFullYear();

export type DiscountsPageProps = {
  offer_codes: OfferCode[];
  pages: Page[];
  products: Product[];
  pagination: PaginationProps;
  show_black_friday_banner: boolean;
  black_friday_code: string;
  black_friday_code_name: string;
};

const DiscountsPage = ({
  offer_codes,
  pages,
  products,
  pagination: initialPagination,
  show_black_friday_banner,
  black_friday_code,
  black_friday_code_name,
}: DiscountsPageProps) => {
  const loggedInUser = useLoggedInUser();
  const [{ offerCodes, pagination }, setState] = React.useState<{
    offerCodes: OfferCode[];
    pagination: PaginationProps;
  }>({
    offerCodes: offer_codes.map((offerCode) => ({ ...offerCode, revenue_cents: null, uses: null })),
    pagination: initialPagination,
  });

  const [offerCodeStatistics, setOfferCodeStatistics] = React.useState<Record<string, OfferCodeStatistics>>({});
  const offerCodeStatisticsRequests = React.useRef<Set<string>>(new Set());

  React.useEffect(() => {
    for (const { id } of offerCodes) {
      if (offerCodeStatisticsRequests.current.has(id)) continue;
      offerCodeStatisticsRequests.current.add(id);
      void getStatistics(id).then(
        (statistics) => setOfferCodeStatistics((prev) => ({ ...prev, [id]: statistics })),
        (err: unknown) => {
          if (err instanceof AbortError) return;
          assertResponseError(err);
          showAlert(err.message, "error");
          offerCodeStatisticsRequests.current.delete(id);
        },
      );
    }
  }, [offerCodes]);

  const [view, setView] = React.useState<"list" | "create" | "edit">("list");
  const [isBlackFridayMode, setIsBlackFridayMode] = React.useState(false);

  const [selectedOfferCodeId, setSelectedOfferCodeId] = React.useState<string | null>(null);
  const selectedOfferCode = offerCodes.find(({ id }) => id === selectedOfferCodeId);
  const selectedOfferCodeStatistics = offerCodeStatistics[selectedOfferCodeId ?? ""];

  // Handle browser actions for navigating to the previous/next page
  useGlobalEventListener("popstate", (e: PopStateEvent) => {
    const params = is<QueryParams>(e.state) ? e.state : extractParams(new URLSearchParams(window.location.search));
    const newSort = params.sort;
    const newQuery = params.query;
    const page = params.page ?? 1;
    setSort(newSort);
    setSearchQuery(newQuery);
    setState({ offerCodes, pagination: { ...pagination, page } });
    loadDiscounts({ page, query: newQuery, sort: newSort, keepUrl: true });
  });
  const setUrlQueryParams = (params: QueryParams): void => {
    const currentUrl = new URL(window.location.href);
    const newUrl = writeQueryParams(currentUrl, {
      page: params.page?.toString() || null,
      query: params.query || null,
      sort: params.sort?.direction || null,
      column: params.sort?.key || null,
    });
    if (newUrl.toString() !== window.location.href) window.history.pushState(params, document.title, newUrl.toString());
  };

  const resetQueryState = () => {
    setSort(null);
    setSearchQuery(null);
    setUrlQueryParams({
      query: null,
      sort: null,
      page: null,
    });
  };

  const [popoverOfferCodeId, setPopoverOfferCodeId] = React.useState<string | null>(null);
  const [isLoading, setIsLoading] = React.useState(false);
  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);

  const originalLocation = useOriginalLocation();
  const initialQueryParams = extractParams(new URL(originalLocation).searchParams);

  const [sort, setSort] = React.useState<Sort<SortKey> | null>(initialQueryParams.sort);
  const thProps = useSortingTableDriver<SortKey>(sort, (newSort) => {
    loadDiscounts({ page: 1, query: searchQuery, sort: newSort });
    setSort(newSort);
  });

  const [searchQuery, setSearchQuery] = React.useState<string | null>(initialQueryParams.query);

  const loadDiscounts = asyncVoid(async ({ page, query, sort, keepUrl }: QueryParams & { keepUrl?: boolean }) => {
    try {
      activeRequest.current?.cancel();
      setIsLoading(true);

      if (!keepUrl)
        setUrlQueryParams({
          query,
          sort,
          page: pagination.pages > 1 ? page : null,
        });

      const request = getPagedDiscounts(page || 1, query, sort);
      activeRequest.current = request;

      const { offer_codes: offerCodes, pagination: newPagination } = await request.response;
      setState({ offerCodes, pagination: newPagination });
      setIsLoading(false);
      activeRequest.current = null;
    } catch (e) {
      if (e instanceof AbortError) return;
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  const reloadDiscounts = () => loadDiscounts({ page: pagination.page, query: searchQuery, sort });

  const debouncedLoadDiscounts = useDebouncedCallback(() => loadDiscounts({ page: 1, query: searchQuery, sort }), 300);

  const deleteOfferCode = async (id: string) => {
    await deleteDiscount(id);
    reloadDiscounts();
    showAlert("Successfully deleted discount!", "success");
  };

  const currentSeller = useCurrentSeller();
  if (!currentSeller) return null;

  const userAgentInfo = useUserAgentInfo();

  const formatDateTime = (date: Date) =>
    date.toLocaleDateString(userAgentInfo.locale, {
      month: "short",
      day: "numeric",
      year: date.getFullYear() !== year ? "numeric" : undefined,
      hour: "numeric",
      timeZone: currentSeller.timeZone.name,
    });
  const formatDate = (date: Date) =>
    date.toLocaleDateString(userAgentInfo.locale, {
      day: "numeric",
      month: "short",
      year: date.getFullYear() !== year ? "numeric" : undefined,
      timeZone: currentSeller.timeZone.name,
    });

  return view === "list" ? (
    <Layout
      currentPage="discounts"
      pages={pages}
      actions={
        <>
          {offerCodes.length > 0 || searchQuery ? (
            <Search
              onSearch={(query) => {
                setSearchQuery(query);
                debouncedLoadDiscounts();
              }}
              value={searchQuery ?? ""}
            />
          ) : null}
          <Button
            color="accent"
            onClick={() => {
              setIsBlackFridayMode(false);
              setSelectedOfferCodeId(null);
              setView("create");
            }}
            disabled={!loggedInUser?.policies.checkout_offer_code.create}
          >
            New discount
          </Button>
        </>
      }
    >
      <section className="p-4 md:p-8">
        {show_black_friday_banner && !offerCodes.some((offerCode) => offerCode.code === black_friday_code) ? (
          <Alert className="mb-8" role="status" variant="accent">
            <div className="flex items-center gap-4">
              <img src={blackFridayIllustration} alt="Black Friday" className="size-12" />
              <div className="flex-1 text-sm md:text-base">
                <span className="font-bold">Black Friday is here!</span> Be part of it on Discover. Join Black Friday
                Deals to create your discount and get featured.
              </div>
              <Button
                color="primary"
                className="w-max"
                onClick={() => {
                  setIsBlackFridayMode(true);
                  setSelectedOfferCodeId(null);
                  setView("create");
                }}
              >
                Join Black Friday Deals
              </Button>
            </div>
          </Alert>
        ) : null}
        {offerCodes.length > 0 ? (
          <section className="flex flex-col gap-4">
            <Table aria-live="polite" className={cx(isLoading && "pointer-events-none opacity-50")}>
              <TableHeader>
                <TableRow>
                  <TableHead {...thProps("name")}>Discount</TableHead>
                  <TableHead {...thProps("revenue")}>Revenue</TableHead>
                  <TableHead {...thProps("uses")}>Uses</TableHead>
                  <TableHead {...thProps("term")}>Term</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {offerCodes.map((offerCode) => {
                  const validAt = offerCode.valid_at ? new Date(offerCode.valid_at) : null;
                  const expiresAt = offerCode.expires_at ? new Date(offerCode.expires_at) : null;
                  const currentDate = new Date();
                  const statistics = offerCodeStatistics[offerCode.id];

                  return (
                    <TableRow
                      key={offerCode.id}
                      selected={offerCode.id === selectedOfferCodeId}
                      onClick={() => setSelectedOfferCodeId(offerCode.id)}
                    >
                      <TableCell hideLabel>
                        <div className="grid gap-2">
                          <div>
                            <Pill size="small" className="mr-2" aria-label="Offer code">
                              {offerCode.code.toUpperCase()}
                            </Pill>
                            <b>{offerCode.name}</b>
                          </div>
                          <small>
                            {formatAmount(offerCode)} off of {formatProducts(offerCode)}
                          </small>
                        </div>
                      </TableCell>
                      <TableCell className="whitespace-nowrap" aria-busy={!statistics}>
                        {statistics ? formatRevenue(statistics.revenue_cents) : <Skeleton className="w-16" />}
                      </TableCell>
                      <TableCell className="whitespace-nowrap" aria-busy={!statistics}>
                        {statistics ? (
                          formatUses(statistics.uses.total, offerCode.limit)
                        ) : (
                          <Skeleton className="w-16" />
                        )}
                      </TableCell>
                      <TableCell>{`${validAt ? `${formatDate(validAt)} - ` : ""}${
                        expiresAt ? formatDate(expiresAt) : "No end date"
                      }`}</TableCell>
                      <TableCell className="whitespace-nowrap">
                        <div className="grid grid-cols-[min-content_1fr] gap-2">
                          {validAt && currentDate < validAt ? (
                            <>Scheduled</>
                          ) : expiresAt && currentDate > expiresAt ? (
                            <>Expired</>
                          ) : (
                            <>Live</>
                          )}
                        </div>
                      </TableCell>
                      <TableCell>
                        <div className="flex flex-wrap gap-3 lg:justify-end">
                          <Button
                            aria-label="Edit"
                            disabled={!offerCode.can_update || isLoading}
                            onClick={() => {
                              setSelectedOfferCodeId(offerCode.id);
                              setView("edit");
                            }}
                          >
                            <Icon name="pencil" />
                          </Button>
                          <Popover
                            open={popoverOfferCodeId === offerCode.id}
                            onOpenChange={(open) => {
                              setPopoverOfferCodeId(open ? offerCode.id : null);
                            }}
                          >
                            <PopoverTrigger asChild>
                              <Button aria-label="Open discount action menu" onClick={(e) => e.stopPropagation()}>
                                <Icon name="three-dots" />
                              </Button>
                            </PopoverTrigger>
                            <PopoverContent sideOffset={4} className="border-0 p-0 shadow-none">
                              <div role="menu">
                                <div
                                  role="menuitem"
                                  inert={!offerCode.can_update || isLoading}
                                  onClick={() => {
                                    setPopoverOfferCodeId(null);
                                    setSelectedOfferCodeId(offerCode.id);
                                    setView("create");
                                  }}
                                >
                                  <Icon name="outline-duplicate" />
                                  &ensp;Duplicate
                                </div>
                                <div
                                  role="menuitem"
                                  className="danger"
                                  inert={!offerCode.can_update || isLoading}
                                  onClick={asyncVoid(async (e) => {
                                    e.stopPropagation();
                                    try {
                                      setIsLoading(true);
                                      setPopoverOfferCodeId(null);
                                      await deleteOfferCode(offerCode.id);
                                    } catch (e) {
                                      assertResponseError(e);
                                      showAlert(e.message, "error");
                                    }
                                    setIsLoading(false);
                                  })}
                                >
                                  <Icon name="trash2" />
                                  &ensp;Delete
                                </div>
                              </div>
                            </PopoverContent>
                          </Popover>
                        </div>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
            {pagination.pages > 1 ? (
              <Pagination
                onChangePage={(newPage) => loadDiscounts({ page: newPage, query: searchQuery, sort })}
                pagination={pagination}
              />
            ) : null}
          </section>
        ) : (
          <Placeholder>
            <PlaceholderImage src={placeholder} />
            <div>
              <h2>No discounts yet</h2>
              <p>Use discounts to create sweet deals for your customers</p>
              <p>
                <a href="/help/article/128-discount-codes" target="_blank" rel="noreferrer">
                  Learn more about discount codes
                </a>
              </p>
            </div>
          </Placeholder>
        )}
        {selectedOfferCode ? (
          <Sheet open onOpenChange={() => setSelectedOfferCodeId(null)}>
            <SheetHeader>{selectedOfferCode.name || selectedOfferCode.code.toUpperCase()}</SheetHeader>
            <Card asChild>
              <section>
                <CardContent asChild>
                  <h3>Details</h3>
                </CardContent>
                <CardContent>
                  <h5 className="grow font-bold">Code</h5>
                  <Pill size="small">{selectedOfferCode.code.toUpperCase()}</Pill>
                </CardContent>
                <CardContent>
                  <h5 className="grow font-bold">Discount</h5>
                  {formatAmount(selectedOfferCode)}
                </CardContent>
                {selectedOfferCodeStatistics != null ? (
                  <>
                    <CardContent>
                      <h5 className="grow font-bold">Uses</h5>
                      {formatUses(selectedOfferCodeStatistics.uses.total, selectedOfferCode.limit)}
                    </CardContent>
                    <CardContent>
                      <h5 className="grow font-bold">Revenue</h5>
                      {formatRevenue(selectedOfferCodeStatistics.revenue_cents)}
                    </CardContent>
                  </>
                ) : null}
                {selectedOfferCode.valid_at ? (
                  <CardContent>
                    <h5 className="grow font-bold">Start date</h5>
                    {formatDateTime(new Date(selectedOfferCode.valid_at))}
                  </CardContent>
                ) : null}
                {selectedOfferCode.expires_at ? (
                  <CardContent>
                    <h5 className="grow font-bold">End date</h5>
                    {formatDateTime(new Date(selectedOfferCode.expires_at))}
                  </CardContent>
                ) : null}
                {selectedOfferCode.minimum_quantity !== null ? (
                  <CardContent>
                    <h5 className="grow font-bold">Minimum quantity</h5>
                    {selectedOfferCode.minimum_quantity}
                  </CardContent>
                ) : null}
                {(selectedOfferCode.products ?? products).some(({ is_tiered_membership }) => is_tiered_membership) ? (
                  <CardContent>
                    <h5 className="grow font-bold">Discount duration for memberships</h5>
                    {selectedOfferCode.duration_in_billing_cycles === 1
                      ? "Once (first billing period only)"
                      : "Forever"}
                  </CardContent>
                ) : null}
                {selectedOfferCode.minimum_amount_cents !== null ? (
                  <CardContent>
                    <h5 className="grow font-bold">Minimum amount</h5>
                    {formatPriceCentsWithCurrencySymbol(
                      selectedOfferCode.currency_type,
                      selectedOfferCode.minimum_amount_cents,
                      {
                        symbolFormat: "short",
                      },
                    )}
                  </CardContent>
                ) : null}
              </section>
            </Card>
            {selectedOfferCode.products ? (
              <Card asChild>
                <section>
                  <CardContent asChild>
                    <h3>Products</h3>
                  </CardContent>
                  {selectedOfferCode.products.map((product) => {
                    const uses =
                      selectedOfferCodeStatistics != null
                        ? (selectedOfferCodeStatistics.uses.products[product.id] ?? 0)
                        : null;
                    return (
                      <CardContent key={product.id} className="grid grid-cols-[1fr_auto] gap-2">
                        <div className="grow">
                          <h5 className="font-bold">{product.name}</h5>
                          {uses != null ? `${uses} ${uses === 1 ? "use" : "uses"}` : null}
                        </div>
                        <CopyToClipboard
                          tooltipPosition="bottom"
                          copyTooltip="Copy link with discount"
                          text={`${product.url}/${selectedOfferCode.code}`}
                        >
                          <Button aria-label="Copy link with discount">
                            <Icon name="link" />
                          </Button>
                        </CopyToClipboard>
                      </CardContent>
                    );
                  })}
                </section>
              </Card>
            ) : null}
            <section className="grid auto-cols-fr grid-flow-row gap-4 sm:grid-flow-col">
              <Button onClick={() => setView("create")} disabled={!selectedOfferCode.can_update || isLoading}>
                Duplicate
              </Button>
              <Button onClick={() => setView("edit")} disabled={!selectedOfferCode.can_update || isLoading}>
                Edit
              </Button>
              <Button
                color="danger"
                onClick={asyncVoid(async () => {
                  if (!selectedOfferCodeId) return;
                  try {
                    setIsLoading(true);
                    await deleteOfferCode(selectedOfferCodeId);
                    setSelectedOfferCodeId(null);
                  } catch (e) {
                    assertResponseError(e);
                    showAlert(e.message, "error");
                  }
                  setIsLoading(false);
                })}
                disabled={!selectedOfferCode.can_update || isLoading}
              >
                {isLoading ? "Deleting..." : "Delete"}
              </Button>
            </section>
          </Sheet>
        ) : null}
      </section>
    </Layout>
  ) : view === "edit" ? (
    <Form
      black_friday_code={black_friday_code}
      black_friday_code_name={black_friday_code_name}
      title="Edit discount"
      submitLabel={isLoading ? "Saving changes..." : "Save changes"}
      readOnlyCode
      offerCode={selectedOfferCode}
      cancel={() => setView("list")}
      save={asyncVoid(async (offerCode) => {
        if (!selectedOfferCode) return;
        try {
          setIsLoading(true);
          const { offer_codes: offerCodes, pagination } = await updateDiscount(selectedOfferCode.id, {
            name: offerCode.name,
            code: offerCode.code,
            maxQuantity: offerCode.limit,
            discount: offerCode.discount,
            selectedProductIds: offerCode.products?.map(({ id }) => id) ?? [],
            currencyCode: offerCode.discount.type === "cents" ? offerCode.currency_type : null,
            universal: !offerCode.products,
            validAt: offerCode.valid_at,
            expiresAt: offerCode.expires_at,
            minimumQuantity: offerCode.minimum_quantity,
            durationInBillingCycles: offerCode.duration_in_billing_cycles,
            minimumAmount: offerCode.minimum_amount_cents,
          });
          resetQueryState();
          setState({ offerCodes, pagination });
          showAlert("Successfully updated discount!", "success");
          setView("list");
        } catch (e) {
          assertResponseError(e);
          showAlert(e.message, "error");
        } finally {
          setIsLoading(false);
        }
      })}
      products={products}
      isLoading={isLoading}
    />
  ) : (
    <Form
      black_friday_code={black_friday_code}
      black_friday_code_name={black_friday_code_name}
      title="Create discount"
      submitLabel={isLoading ? "Adding discount..." : "Add discount"}
      offerCode={selectedOfferCode ? { ...selectedOfferCode, code: "" } : undefined}
      isBlackFridayMode={isBlackFridayMode}
      cancel={() => {
        setIsBlackFridayMode(false);
        setView("list");
      }}
      save={asyncVoid(async (offerCode) => {
        try {
          setIsLoading(true);
          const { offer_codes: offerCodes, pagination } = await createDiscount({
            name: offerCode.name,
            code: offerCode.code,
            maxQuantity: offerCode.limit,
            discount: offerCode.discount,
            selectedProductIds: offerCode.products?.map(({ id }) => id) ?? [],
            currencyCode: offerCode.discount.type === "cents" ? offerCode.currency_type : null,
            universal: !offerCode.products,
            validAt: offerCode.valid_at,
            expiresAt: offerCode.expires_at,
            minimumQuantity: offerCode.minimum_quantity,
            durationInBillingCycles: offerCode.duration_in_billing_cycles,
            minimumAmount: offerCode.minimum_amount_cents,
          });
          resetQueryState();
          setState({ offerCodes, pagination });
          setSelectedOfferCodeId(offerCodes[0]?.id ?? null);
          showAlert("Successfully created discount!", "success");
          setView("list");
        } catch (e) {
          assertResponseError(e);
          showAlert(e.message, "error");
        } finally {
          setIsLoading(false);
        }
      })}
      products={products}
      isLoading={isLoading}
    />
  );
};

const generateCode = () => Math.random().toString(36).substring(2, 9);
const Form = ({
  title,
  offerCode,
  readOnlyCode,
  submitLabel,
  cancel,
  save,
  products,
  isLoading,
  black_friday_code,
  black_friday_code_name,
  isBlackFridayMode = false,
}: {
  title: string;
  offerCode?: OfferCode | undefined;
  readOnlyCode?: boolean;
  submitLabel: string;
  cancel: () => void;
  save: (offerCode: Omit<OfferCode, "id" | "can_update">) => void;
  products: Product[];
  isLoading: boolean;
  black_friday_code: string;
  black_friday_code_name: string;
  isBlackFridayMode?: boolean;
}) => {
  const [name, setName] = React.useState<{ value: string; error?: boolean }>({
    value: isBlackFridayMode ? black_friday_code_name : (offerCode?.name ?? ""),
  });
  const [code, setCode] = React.useState<{ value: string; error?: boolean }>({
    value: isBlackFridayMode ? black_friday_code : offerCode?.code || generateCode(),
  });

  const [discount, setDiscount] = React.useState<InputtedDiscount>(
    offerCode?.discount ?? {
      type: "percent",
      value: 0,
    },
  );

  const nameFieldRef = React.useRef<HTMLInputElement>(null);
  const codeFieldRef = React.useRef<HTMLInputElement>(null);
  const selectedProductsFieldRef = React.useRef<SelectInstance<Option, true, GroupBase<Option>>>(null);

  const [universal, setUniversal] = React.useState(offerCode ? offerCode.products === null : false);
  const [selectedProductIds, setSelectedProductIds] = React.useState<{ value: string[]; error?: boolean }>({
    value: offerCode?.products?.map(({ id }) => id) ?? [],
  });
  const selectedProducts = products.filter(({ id }) => selectedProductIds.value.includes(id));

  const [limitQuantity, setLimitQuantity] = React.useState(!!offerCode?.limit);
  const [maxQuantity, setMaxQuantity] = React.useState<{ value: number | null; error?: boolean }>({
    value: offerCode?.limit ?? null,
  });

  const [limitValidity, setLimitValidity] = React.useState(!!offerCode?.valid_at);
  const [validAt, setValidAt] = React.useState(offerCode?.valid_at ? new Date(offerCode.valid_at) : new Date());
  const [expiresAt, setExpiresAt] = React.useState<{ error?: boolean; value: Date }>({
    value: offerCode?.expires_at
      ? new Date(offerCode.expires_at)
      : new Date(new Date().setHours(new Date().getHours() + 1)),
  });
  const [hasNoEndDate, setHasNoEndDate] = React.useState(!offerCode?.expires_at);

  const [hasMinimumQuantity, setHasMinimumQuantity] = React.useState(!!offerCode?.minimum_quantity);
  const [minimumQuantity, setMinimumQuantity] = React.useState<{ value: number | null; error?: boolean }>({
    value: offerCode?.minimum_quantity ?? null,
  });

  const [hasMinimumAmount, setHasMinimumAmount] = React.useState(!!offerCode?.minimum_amount_cents);
  const [minimumAmount, setMinimumAmount] = React.useState<{ value: number | null; error?: boolean }>({
    value: offerCode?.minimum_amount_cents ?? null,
  });

  const [currencyCode, setCurrencyCode] = React.useState(
    offerCode?.currency_type ?? selectedProducts[0]?.currency_type ?? products[0]?.currency_type ?? "usd",
  );

  const canSetDuration = (universal ? products : selectedProducts).some(
    ({ is_recurring_billing }) => is_recurring_billing,
  );
  const [durationInBillingCycles, setDurationInMonths] = React.useState(offerCode?.duration_in_billing_cycles ?? null);

  const uid = React.useId();

  const handleSubmit = () => {
    const isNameInvalid = name.value === "";
    const isCodeInvalid = code.value === "";
    const isDiscountInvalid = discount.value === null;
    const isMaxQuantityInvalid = limitQuantity && maxQuantity.value === null;
    const isExpiresAtInvalid = !hasNoEndDate && validAt > expiresAt.value;
    const isSelectedProductsInvalid = !universal && selectedProductIds.value.length === 0;
    const isMinimumQuantityInvalid = hasMinimumQuantity && minimumQuantity.value === null;
    const isMinimumAmountInvalid = hasMinimumAmount && minimumAmount.value === null;

    const hasValidationErrors =
      isNameInvalid ||
      isCodeInvalid ||
      isDiscountInvalid ||
      isMaxQuantityInvalid ||
      isExpiresAtInvalid ||
      isSelectedProductsInvalid ||
      isMinimumQuantityInvalid ||
      isMinimumAmountInvalid;

    if (hasValidationErrors) {
      setName((prev) => ({ ...prev, error: isNameInvalid }));
      setCode((prev) => ({ ...prev, error: isCodeInvalid }));
      setDiscount((prev) => ({ ...prev, error: isDiscountInvalid }));
      setMaxQuantity((prev) => ({ ...prev, error: isMaxQuantityInvalid }));
      setExpiresAt((prev) => ({ ...prev, error: isExpiresAtInvalid }));
      setSelectedProductIds((prev) => ({ ...prev, error: isSelectedProductsInvalid }));
      setMinimumQuantity((prev) => ({ ...prev, error: isMinimumQuantityInvalid }));
      setMinimumAmount((prev) => ({ ...prev, error: isMinimumAmountInvalid }));

      const invalidFieldRefs = [];
      if (isNameInvalid) invalidFieldRefs.push(nameFieldRef);
      if (isCodeInvalid) invalidFieldRefs.push(codeFieldRef);
      if (isSelectedProductsInvalid) invalidFieldRefs.push(selectedProductsFieldRef);

      if (invalidFieldRefs[0]?.current) {
        invalidFieldRefs[0].current.focus();
        showAlert("Please fill out the required fields.", "error");
      }

      return;
    }

    save({
      name: name.value,
      code: code.value,
      products: universal ? null : selectedProducts.map((product) => ({ ...product, uses: 0 })),
      discount: { type: discount.type, value: discount.value ?? 0 },
      limit: limitQuantity ? maxQuantity.value : null,
      currency_type: currencyCode,
      valid_at: limitValidity ? validAt.toISOString() : null,
      expires_at: limitValidity && !hasNoEndDate ? expiresAt.value.toISOString() : null,
      minimum_quantity: hasMinimumQuantity ? minimumQuantity.value : null,
      duration_in_billing_cycles: canSetDuration ? durationInBillingCycles : null,
      minimum_amount_cents: hasMinimumAmount ? minimumAmount.value : null,
    });
  };

  return (
    <div>
      <PageHeader
        title={title}
        actions={
          <>
            <Button onClick={cancel} disabled={isLoading}>
              <Icon name="x-square" />
              Cancel
            </Button>
            <Button color="accent" onClick={handleSubmit} disabled={isLoading}>
              {submitLabel}
            </Button>
          </>
        }
      />
      <form>
        <section className="p-8!">
          <header>
            <div className="flex flex-col gap-4">
              <div>Create a discount code so your audience can buy your products at a reduced price.</div>
              <div>
                Once the code is created, you can share it or copy a unique link per product that automatically applies
                the discount.
              </div>
              <div>
                <a href="/help/article/128-discount-codes" target="_blank" rel="noreferrer">
                  Learn more
                </a>
              </div>
            </div>
          </header>
          <fieldset className={cx({ danger: name.error })}>
            <legend>
              <label htmlFor={`${uid}name`}>Name</label>
            </legend>
            <input
              type="text"
              id={`${uid}name`}
              placeholder="Black Friday"
              value={name.value}
              ref={nameFieldRef}
              onChange={(evt) => setName({ value: evt.target.value })}
              aria-invalid={name.error}
            />
          </fieldset>
          <fieldset className={cx({ danger: code.error })}>
            <legend>
              <label htmlFor={`${uid}code`}>Discount code</label>
            </legend>
            <div className="grid grid-cols-[1fr_auto] gap-2">
              <input
                type="text"
                id={`${uid}code`}
                value={code.value}
                ref={codeFieldRef}
                onChange={(evt) => {
                  setCode({ value: evt.target.value });
                }}
                aria-invalid={code.error}
                readOnly={readOnlyCode || isBlackFridayMode}
              />
              <Button
                onClick={() => {
                  setCode({ value: generateCode() });
                }}
                aria-label="Generate new discount"
                disabled={readOnlyCode || isBlackFridayMode}
              >
                <Icon name="outline-refresh" />
              </Button>
            </div>
            {isBlackFridayMode ? (
              <Alert className="mt-2" variant="info">
                By using this discount, your product will be featured in Black Friday Deals on Discover.
              </Alert>
            ) : null}
          </fieldset>
          <fieldset className={cx({ danger: selectedProductIds.error })}>
            <legend>
              <label htmlFor={`${uid}products`}>Products</label>
            </legend>
            <Select
              ref={selectedProductsFieldRef}
              inputId={`${uid}products`}
              instanceId={`${uid}products`}
              options={products
                .filter(
                  ({ currency_type }) =>
                    discount.type !== "cents" ||
                    selectedProductIds.value.length === 0 ||
                    currency_type === currencyCode,
                )
                .filter((product) => !product.archived)
                .map((product) => ({ id: product.id, label: product.name }))}
              value={selectedProducts.map(({ id, name: label }) => ({
                id,
                label,
              }))}
              isMulti
              isClearable
              placeholder="Products to which this discount will apply"
              onChange={(selectedIds) => {
                setSelectedProductIds({ value: selectedIds.map(({ id }) => id) });
                setCurrencyCode(
                  (prevCurrencyCode) =>
                    products.find(({ id }) => id === selectedIds[0]?.id)?.currency_type ?? prevCurrencyCode,
                );
              }}
              isDisabled={universal}
              aria-invalid={selectedProductIds.error}
            />
            <label>
              <input
                type="checkbox"
                checked={universal}
                onChange={(evt) => {
                  setUniversal(evt.target.checked);
                  setSelectedProductIds({ value: [] });
                }}
                aria-invalid={selectedProductIds.error}
              />
              All products
            </label>
          </fieldset>
          {canSetDuration ? (
            <fieldset>
              <legend>
                <label htmlFor={`${uid}duration`}>Discount duration for memberships</label>
              </legend>
              <TypeSafeOptionSelect
                id={`${uid}duration`}
                value={durationInBillingCycles === null ? "forever" : "once"}
                onChange={(id) => setDurationInMonths(id === "forever" ? null : 1)}
                options={[
                  { id: "forever", label: "Forever" },
                  { id: "once", label: "Once (first billing period only)" },
                ]}
              />
            </fieldset>
          ) : null}
          <fieldset>
            <legend>Type</legend>
            <DiscountInput
              discount={discount}
              setDiscount={setDiscount}
              currencyCode={currencyCode}
              currencyCodeSelector={
                universal
                  ? {
                      options: [...new Set(products.map(({ currency_type }) => currency_type))],
                      onChange: setCurrencyCode,
                    }
                  : undefined
              }
              disableFixedAmount={
                discount.type === "percent" &&
                !universal &&
                !selectedProducts.every(({ currency_type }) => currency_type === currencyCode)
              }
            />
          </fieldset>
          <fieldset className="gap-4">
            <legend>Settings</legend>
            <Details
              className="toggle"
              open={limitQuantity}
              summary={
                <label>
                  <input
                    type="checkbox"
                    role="switch"
                    checked={limitQuantity}
                    onChange={(evt) => setLimitQuantity(evt.target.checked)}
                  />
                  Limit quantity
                </label>
              }
            >
              <Dropdown>
                <fieldset className={cx({ danger: maxQuantity.error })}>
                  <legend>
                    <label htmlFor={`${uid}quantity`}>Quantity</label>
                  </legend>
                  <NumberInput
                    value={maxQuantity.value}
                    onChange={(value) => {
                      if (value === null || value >= 0) setMaxQuantity({ value });
                    }}
                  >
                    {(props) => (
                      <input id={`${uid}quantity`} placeholder="0" aria-invalid={maxQuantity.error} {...props} />
                    )}
                  </NumberInput>
                </fieldset>
              </Dropdown>
            </Details>
            <Details
              className="toggle"
              open={limitValidity}
              summary={
                <label>
                  <input
                    type="checkbox"
                    role="switch"
                    checked={limitValidity}
                    onChange={(evt) => setLimitValidity(evt.target.checked)}
                  />
                  Limit validity period
                </label>
              }
            >
              <Dropdown className="gap-4 lg:grid-cols-2">
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}validAt`}>Valid from</label>
                  </legend>
                  <DateInput
                    withTime
                    id={`${uid}validAt`}
                    value={validAt}
                    onChange={(date) => {
                      if (date) setValidAt(date);
                    }}
                  />
                  <label>
                    <input
                      type="checkbox"
                      checked={hasNoEndDate}
                      onChange={(evt) => setHasNoEndDate(evt.target.checked)}
                    />
                    No end date
                  </label>
                </fieldset>
                <fieldset className={cx({ danger: expiresAt.error })}>
                  <legend>
                    <label htmlFor={`${uid}expiresAt`}>Valid until</label>
                  </legend>
                  <DateInput
                    withTime
                    id={`${uid}expiresAt`}
                    value={expiresAt.value}
                    onChange={(value) => {
                      if (value) setExpiresAt({ value });
                    }}
                    disabled={hasNoEndDate}
                    aria-invalid={expiresAt.error ?? false}
                  />
                </fieldset>
              </Dropdown>
            </Details>
            <Details
              className="toggle"
              open={hasMinimumAmount}
              summary={
                <label>
                  <input
                    type="checkbox"
                    role="switch"
                    checked={hasMinimumAmount}
                    onChange={(evt) => setHasMinimumAmount(evt.target.checked)}
                  />
                  Set a minimum qualifying amount
                </label>
              }
            >
              <Dropdown>
                <fieldset className={cx({ danger: minimumAmount.error })}>
                  <legend>
                    <label htmlFor={`${uid}minimumAmount`}>Minimum amount</label>
                  </legend>
                  <PriceInput
                    id={`${uid}minimumAmount`}
                    currencyCode={currencyCode}
                    cents={minimumAmount.value}
                    onChange={(value) => setMinimumAmount({ value })}
                    placeholder="0"
                    hasError={minimumAmount.error ?? false}
                  />
                </fieldset>
              </Dropdown>
            </Details>
            <Details
              className="toggle"
              open={hasMinimumQuantity}
              summary={
                <label>
                  <input
                    type="checkbox"
                    role="switch"
                    checked={hasMinimumQuantity}
                    onChange={(evt) => setHasMinimumQuantity(evt.target.checked)}
                  />
                  Set a minimum quantity
                </label>
              }
            >
              <Dropdown>
                <fieldset className={cx({ danger: minimumQuantity.error })}>
                  <legend>
                    <label htmlFor={`${uid}minimumQuantity`}>Minimum quantity per product</label>
                  </legend>
                  <NumberInput
                    value={minimumQuantity.value}
                    onChange={(value) => {
                      if (value === null || value >= 0) setMinimumQuantity({ value });
                    }}
                  >
                    {(props) => (
                      <input
                        id={`${uid}minimumQuantity`}
                        placeholder="0"
                        aria-invalid={minimumQuantity.error}
                        {...props}
                      />
                    )}
                  </NumberInput>
                </fieldset>
              </Dropdown>
            </Details>
          </fieldset>
        </section>
      </form>
    </div>
  );
};

export default DiscountsPage;
