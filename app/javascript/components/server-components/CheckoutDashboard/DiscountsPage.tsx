import cx from "classnames";
import * as React from "react";
import { createCast, is } from "ts-safe-cast";

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
import { register } from "$app/utils/serverComponentUtil";
import { writeQueryParams } from "$app/utils/url";

import { Button } from "$app/components/Button";
import { DiscountInput, InputtedDiscount } from "$app/components/CheckoutDashboard/DiscountInput";
import { Layout, Page } from "$app/components/CheckoutDashboard/Layout";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { DateInput } from "$app/components/DateInput";
import { Details } from "$app/components/Details";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NumberInput } from "$app/components/NumberInput";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Popover } from "$app/components/Popover";
import { PriceInput } from "$app/components/PriceInput";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { PageHeader } from "$app/components/ui/PageHeader";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useSortingTableDriver, Sort } from "$app/components/useSortingTableDriver";

import placeholder from "$assets/images/placeholders/discounts.png";

type Product = {
  id: string;
  name: string;
  currency_type: CurrencyCode;
  url: string;
  is_tiered_membership: boolean;
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

const DiscountsPage = ({
  offer_codes,
  pages,
  products,
  pagination: initialPagination,
}: {
  pages: Page[];
  offer_codes: OfferCode[];
  products: Product[];
  pagination: PaginationProps;
}) => {
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
  const [isSearchPopoverOpen, setIsSearchPopoverOpen] = React.useState(false);
  const searchInputRef = React.useRef<HTMLInputElement | null>(null);

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

  React.useEffect(() => {
    if (isSearchPopoverOpen) searchInputRef.current?.focus();
  }, [isSearchPopoverOpen]);

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
          <Popover
            open={isSearchPopoverOpen}
            onToggle={setIsSearchPopoverOpen}
            aria-label="Search"
            trigger={
              <div className="button">
                <Icon name="solid-search" />
              </div>
            }
          >
            <div className="input">
              <Icon name="solid-search" />
              <input
                ref={searchInputRef}
                type="text"
                placeholder="Search"
                value={searchQuery ?? ""}
                onChange={(evt) => {
                  setSearchQuery(evt.target.value);
                  debouncedLoadDiscounts();
                }}
              />
            </div>
          </Popover>
          <Button
            color="accent"
            onClick={() => {
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
        {offerCodes.length > 0 ? (
          <>
            <table aria-live="polite" aria-busy={isLoading}>
              <thead>
                <tr>
                  <th {...thProps("name")}>Discount</th>
                  <th {...thProps("revenue")}>Revenue</th>
                  <th {...thProps("uses")}>Uses</th>
                  <th {...thProps("term")}>Term</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {offerCodes.map((offerCode) => {
                  const validAt = offerCode.valid_at ? new Date(offerCode.valid_at) : null;
                  const expiresAt = offerCode.expires_at ? new Date(offerCode.expires_at) : null;
                  const currentDate = new Date();
                  const statistics = offerCodeStatistics[offerCode.id];

                  return (
                    <tr
                      key={offerCode.id}
                      aria-selected={offerCode.id === selectedOfferCodeId}
                      onClick={() => setSelectedOfferCodeId(offerCode.id)}
                    >
                      <td>
                        <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                          <div>
                            <div
                              className="pill small"
                              style={{ marginRight: "var(--spacer-2)" }}
                              aria-label="Offer code"
                            >
                              {offerCode.code.toUpperCase()}
                            </div>
                            <b>{offerCode.name}</b>
                          </div>
                          <small>
                            {formatAmount(offerCode)} off of {formatProducts(offerCode)}
                          </small>
                        </div>
                      </td>
                      {statistics != null ? (
                        <>
                          <td style={{ whiteSpace: "nowrap" }}>{formatRevenue(statistics.revenue_cents)}</td>
                          <td style={{ whiteSpace: "nowrap" }}>{formatUses(statistics.uses.total, offerCode.limit)}</td>
                        </>
                      ) : (
                        <>
                          <td aria-busy />
                          <td aria-busy />
                        </>
                      )}
                      <td>{`${validAt ? `${formatDate(validAt)} - ` : ""}${
                        expiresAt ? formatDate(expiresAt) : "No end date"
                      }`}</td>
                      <td style={{ whiteSpace: "nowrap" }}>
                        <div
                          style={{ display: "grid", gridTemplateColumns: "min-content 1fr", gap: "var(--spacer-2)" }}
                        >
                          {validAt && currentDate < validAt ? (
                            <>Scheduled</>
                          ) : expiresAt && currentDate > expiresAt ? (
                            <>Expired</>
                          ) : (
                            <>Live</>
                          )}
                        </div>
                      </td>
                      <td>
                        <div className="actions">
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
                            onToggle={(open) => setPopoverOfferCodeId(open ? offerCode.id : null)}
                            aria-label="Open discount action menu"
                            trigger={
                              <div className="button">
                                <Icon name="three-dots" />
                              </div>
                            }
                          >
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
                                onClick={asyncVoid(async () => {
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
                          </Popover>
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
            {pagination.pages > 1 ? (
              <Pagination
                onChangePage={(newPage) => loadDiscounts({ page: newPage, query: searchQuery, sort })}
                pagination={pagination}
              />
            ) : null}
          </>
        ) : (
          <div className="placeholder">
            <figure>
              <img src={placeholder} />
            </figure>
            <div>
              <h2>No discounts yet</h2>
              <p>Use discounts to create sweet deals for your customers</p>
              <p>
                <a href="/help/article/128-discount-codes" target="_blank" rel="noreferrer">
                  Learn more about discount codes
                </a>
              </p>
            </div>
          </div>
        )}
        {selectedOfferCode ? (
          <aside>
            <header>
              <h2>{selectedOfferCode.name || selectedOfferCode.code.toUpperCase()}</h2>
              <button className="close" aria-label="Close" onClick={() => setSelectedOfferCodeId(null)} />
            </header>
            <section className="stack">
              <h3>Details</h3>
              <div>
                <h5>Code</h5>
                <div className="pill small">{selectedOfferCode.code.toUpperCase()}</div>
              </div>
              <div>
                <h5>Discount</h5>
                {formatAmount(selectedOfferCode)}
              </div>
              {selectedOfferCodeStatistics != null ? (
                <>
                  <div>
                    <h5>Uses</h5>
                    {formatUses(selectedOfferCodeStatistics.uses.total, selectedOfferCode.limit)}
                  </div>
                  <div>
                    <h5>Revenue</h5>
                    {formatRevenue(selectedOfferCodeStatistics.revenue_cents)}
                  </div>
                </>
              ) : null}
              {selectedOfferCode.valid_at ? (
                <div>
                  <h5>Start date</h5>
                  {formatDateTime(new Date(selectedOfferCode.valid_at))}
                </div>
              ) : null}
              {selectedOfferCode.expires_at ? (
                <div>
                  <h5>End date</h5>
                  {formatDateTime(new Date(selectedOfferCode.expires_at))}
                </div>
              ) : null}
              {selectedOfferCode.minimum_quantity !== null ? (
                <div>
                  <h5>Minimum quantity</h5>
                  {selectedOfferCode.minimum_quantity}
                </div>
              ) : null}
              {(selectedOfferCode.products ?? products).some(({ is_tiered_membership }) => is_tiered_membership) ? (
                <div>
                  <h5>Discount duration for memberships</h5>
                  {selectedOfferCode.duration_in_billing_cycles === 1 ? "Once (first billing period only)" : "Forever"}
                </div>
              ) : null}
              {selectedOfferCode.minimum_amount_cents !== null ? (
                <div>
                  <h5>Minimum amount</h5>
                  {formatPriceCentsWithCurrencySymbol(
                    selectedOfferCode.currency_type,
                    selectedOfferCode.minimum_amount_cents,
                    {
                      symbolFormat: "short",
                    },
                  )}
                </div>
              ) : null}
            </section>
            {selectedOfferCode.products ? (
              <section className="stack">
                <h3>Products</h3>
                {selectedOfferCode.products.map((product) => {
                  const uses =
                    selectedOfferCodeStatistics != null
                      ? (selectedOfferCodeStatistics.uses.products[product.id] ?? 0)
                      : null;
                  return (
                    <div
                      key={product.id}
                      style={{ display: "grid", gridTemplateColumns: "1fr auto", gap: "var(--spacer-2)" }}
                    >
                      <div>
                        <h5>{product.name}</h5>
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
                    </div>
                  );
                })}
              </section>
            ) : null}
            <section className="grid auto-cols-fr grid-flow-row sm:grid-flow-col" style={{ gap: "var(--spacer-4)" }}>
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
          </aside>
        ) : null}
      </section>
    </Layout>
  ) : view === "edit" ? (
    <Form
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
      title="Create discount"
      submitLabel={isLoading ? "Adding discount..." : "Add discount"}
      offerCode={selectedOfferCode ? { ...selectedOfferCode, code: "" } : undefined}
      cancel={() => setView("list")}
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
}: {
  title: string;
  offerCode?: OfferCode | undefined;
  readOnlyCode?: boolean;
  submitLabel: string;
  cancel: () => void;
  save: (offerCode: Omit<OfferCode, "id" | "can_update">) => void;
  products: Product[];
  isLoading: boolean;
}) => {
  const [name, setName] = React.useState<{ value: string; error?: boolean }>({ value: offerCode?.name ?? "" });

  const [code, setCode] = React.useState<{ value: string; error?: boolean }>({
    value: offerCode?.code || generateCode(),
  });

  const [discount, setDiscount] = React.useState<InputtedDiscount>(
    offerCode?.discount ?? {
      type: "percent",
      value: 0,
    },
  );

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
    ({ is_tiered_membership }) => is_tiered_membership,
  );
  const [durationInBillingCycles, setDurationInMonths] = React.useState(offerCode?.duration_in_billing_cycles ?? null);

  const uid = React.useId();

  const handleSubmit = () => {
    if (
      name.value === "" ||
      code.value === "" ||
      discount.value === null ||
      (limitQuantity && maxQuantity.value === null) ||
      (!hasNoEndDate && validAt > expiresAt.value) ||
      (!universal && selectedProductIds.value.length === 0) ||
      (hasMinimumQuantity && minimumQuantity.value === null) ||
      (hasMinimumAmount && minimumAmount.value === null)
    ) {
      setName((prevName) => ({ ...prevName, error: prevName.value === "" }));
      setCode((prevCode) => ({ ...prevCode, error: prevCode.value === "" }));
      setDiscount((prevDiscount) => ({ ...prevDiscount, error: prevDiscount.value === null }));
      setMaxQuantity((prevMaxQuantity) => ({
        ...prevMaxQuantity,
        error: limitQuantity && prevMaxQuantity.value === null,
      }));
      setExpiresAt((prevExpiresAt) => ({ ...prevExpiresAt, error: !hasNoEndDate && validAt > prevExpiresAt.value }));
      setSelectedProductIds((prevSelectedProductIds) => ({
        ...prevSelectedProductIds,
        error: !universal && selectedProductIds.value.length === 0,
      }));
      setMinimumQuantity((prevMinimumQuantity) => ({
        ...prevMinimumQuantity,
        error: hasMinimumQuantity && prevMinimumQuantity.value === null,
      }));
      setMinimumAmount((prevMinimumAmount) => ({
        ...prevMinimumAmount,
        error: hasMinimumAmount && prevMinimumAmount.value === null,
      }));
      return;
    }

    save({
      name: name.value,
      code: code.value,
      products: universal ? null : selectedProducts.map((product) => ({ ...product, uses: 0 })),
      discount: { type: discount.type, value: discount.value },
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
        <section className="!p-8">
          <header>
            <div className="paragraphs">
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
              onChange={(evt) => setName({ value: evt.target.value })}
              aria-invalid={name.error}
            />
          </fieldset>
          <fieldset className={cx({ danger: code.error })}>
            <legend>
              <label htmlFor={`${uid}code`}>Discount code</label>
            </legend>
            <div style={{ display: "grid", gridTemplateColumns: "1fr auto", gap: "var(--spacer-2)" }}>
              <input
                type="text"
                id={`${uid}code`}
                value={code.value}
                onChange={(evt) => setCode({ value: evt.target.value })}
                aria-invalid={code.error}
                readOnly={readOnlyCode}
              />
              <Button
                onClick={() => setCode({ value: generateCode() })}
                aria-label="Generate new discount"
                disabled={readOnlyCode}
              >
                <Icon name="outline-refresh" />
              </Button>
            </div>
          </fieldset>
          <fieldset className={cx({ danger: selectedProductIds.error })}>
            <legend>
              <label htmlFor={`${uid}products`}>Products</label>
            </legend>
            <Select
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
          <fieldset style={{ gap: "var(--spacer-4)" }}>
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
              <div className="dropdown">
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
              </div>
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
              <div
                className="dropdown"
                style={{
                  display: "grid",
                  gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
                  gap: "var(--spacer-4)",
                }}
              >
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
              </div>
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
              <div className="dropdown">
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
              </div>
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
              <div className="dropdown">
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
              </div>
            </Details>
          </fieldset>
        </section>
      </form>
    </div>
  );
};

export default register({ component: DiscountsPage, propParser: createCast() });
