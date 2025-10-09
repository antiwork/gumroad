import cx from "classnames";
import { parseISO } from "date-fns";
import * as React from "react";
import * as ReactDOM from "react-dom";
import {
  RouterProvider,
  useNavigate,
  useParams,
  createBrowserRouter,
  Link,
  json,
  useLoaderData,
  useSearchParams,
  useNavigation,
  useRevalidator,
  redirect,
  useLocation,
  RouteObject,
} from "react-router-dom";
import { StaticRouterProvider } from "react-router-dom/server";
import { cast } from "ts-safe-cast";

import { updateAffiliateRequest, approvePendingAffiliateRequests } from "$app/data/affiliate_request";
import {
  getPagedAffiliates,
  removeAffiliate,
  Affiliate,
  AffiliateRequest,
  PagedAffiliatesData,
  getOnboardingAffiliateData,
  AffiliateRequestPayload,
  updateAffiliate,
  addAffiliate,
  loadAffiliate,
  AffiliateStatistics,
  getStatistics,
} from "$app/data/affiliates";
import { assertDefined } from "$app/utils/assert";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { isValidEmail } from "$app/utils/email";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { buildStaticRouter, GlobalProps, register } from "$app/utils/serverComponentUtil";
import { isUrlValid } from "$app/utils/url";

import { AffiliateSignupForm, ProductRow } from "$app/components/AffiliatesDashboard/AffiliateSignupForm";
import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NumberInput } from "$app/components/NumberInput";
import { Pagination } from "$app/components/Pagination";
import { Popover } from "$app/components/Popover";
import { Progress } from "$app/components/Progress";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useLocalPagination } from "$app/components/useLocalPagination";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { Sort, useClientSortingTableDriver, useSortingTableDriver } from "$app/components/useSortingTableDriver";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/affiliated.png";

type LayoutProps = {
  title: string;
  hasStickyHeader?: boolean;
  actions?: React.ReactNode;
  navigation?: React.ReactNode;
  children: React.ReactNode;
};

export const Layout = ({ title, hasStickyHeader, actions, navigation, children }: LayoutProps) =>
  hasStickyHeader ? (
    <>
      <Header title={title} actions={actions} navigation={navigation} sticky />
      <div>{children}</div>
    </>
  ) : (
    <div>
      <Header title={title} actions={actions} navigation={navigation} />
      {children}
    </div>
  );

const Header = ({
  title,
  sticky,
  actions,
  navigation,
}: {
  title: string;
  sticky?: boolean;
  actions?: React.ReactNode;
  navigation?: React.ReactNode;
}) => (
  <PageHeader className={cx({ "sticky-top": sticky })} title={title} actions={actions}>
    {navigation ?? null}
  </PageHeader>
);

export const AffiliatesNavigation = () => {
  const { pathname } = useLocation();

  return (
    <Tabs>
      <Tab href="/affiliates" isSelected={pathname === "/affiliates"}>
        Affiliates
      </Tab>
      <Tab href="/affiliates/onboarding" isSelected={pathname === "/affiliates/onboarding"}>
        Affiliate Signup Form
      </Tab>
    </Tabs>
  );
};

const extractSortParam = (rawParams: URLSearchParams): Sort<SortKey> | null => {
  const column = rawParams.get("column");
  switch (column) {
    case "affiliate_user_name":
    case "products":
    case "fee_percent":
    case "volume_cents":
      return {
        direction: rawParams.get("sort") === "desc" ? "desc" : "asc",
        key: column,
      };
    default:
      return null;
  }
};

const SearchBoxPopover = ({ initialQuery, onSearch }: { initialQuery: string; onSearch: (query: string) => void }) => {
  const [searchBoxOpen, setSearchBoxOpen] = React.useState(false);
  const searchInputRef = React.useRef<HTMLInputElement | null>(null);
  const [searchQuery, setSearchQuery] = React.useState(initialQuery);

  React.useEffect(() => {
    if (searchBoxOpen) searchInputRef.current?.focus();
  }, [searchBoxOpen]);

  return (
    <Popover
      open={searchBoxOpen}
      onToggle={setSearchBoxOpen}
      aria-label="Toggle Search"
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
          value={searchQuery}
          autoFocus
          type="text"
          placeholder="Search"
          onChange={(evt) => {
            const newQuery = evt.target.value;
            setSearchQuery(newQuery);
            onSearch(newQuery);
          }}
        />
      </div>
    </Popover>
  );
};

const ApproveAllButton = ({
  isLoading,
  setIsLoading,
}: {
  isLoading: boolean;
  setIsLoading: (newState: boolean) => void;
}) => (
  <Button
    color="primary"
    onClick={asyncVoid(async () => {
      setIsLoading(true);
      try {
        await approvePendingAffiliateRequests();
        showAlert("Approved", "success");
      } catch (e) {
        assertResponseError(e);
        showAlert("Error approving affiliate requests", "error");
      }
      setIsLoading(false);
    })}
    disabled={isLoading}
  >
    {isLoading ? "Approving" : "Approve all"}
  </Button>
);

const AffiliateRequestsTable = ({
  affiliateRequests: initialAffiliateRequests,
  allowApproveAll,
}: {
  affiliateRequests: AffiliateRequest[];
  allowApproveAll: boolean;
}) => {
  const loggedInUser = useLoggedInUser();
  const userAgentInfo = useUserAgentInfo();
  const [isLoading, setIsLoading] = React.useState(false);
  const [affiliateRequests, setAffiliateRequests] =
    React.useState<(AffiliateRequest & { processingState?: "approve" | "ignore" })[]>(initialAffiliateRequests);

  const update = asyncVoid(async (request: AffiliateRequest, action: "approve" | "ignore") => {
    const error =
      action === "approve"
        ? `An error occurred while approving affiliate request by ${request.name}`
        : `An error occurred while ignoring affiliate request by ${request.name}`;
    setAffiliateRequests((requests) => [
      ...requests.filter((item) => item.id !== request.id),
      { ...request, processingState: action },
    ]);
    try {
      const response = await updateAffiliateRequest(request.id, action);
      if (action === "ignore" || response.requester_has_existing_account) {
        setAffiliateRequests((requests) => requests.filter((item) => item.id !== request.id));
      } else {
        setAffiliateRequests((requests) => [
          ...requests.filter((item) => item.id !== request.id),
          { ...request, state: "approved" },
        ]);
      }
      showAlert(
        action === "approve" ? `Approved ${request.name}'s request!` : `Ignored ${request.name}'s request!`,
        "success",
      );
    } catch (e) {
      assertResponseError(e);
      showAlert(`${error} - ${e.message}`, "error");
    }
  });

  const { items, thProps } = useClientSortingTableDriver(affiliateRequests, { key: "date", direction: "asc" });
  const { items: visibleItems, showMoreItems } = useLocalPagination(items, 20);

  return (
    <>
      {visibleItems.length > 0 ? (
        <table>
          <caption>
            <div style={{ display: "flex", justifyContent: "space-between" }}>
              Requests
              {allowApproveAll ? <ApproveAllButton isLoading={isLoading} setIsLoading={setIsLoading} /> : null}
            </div>
          </caption>
          <thead>
            <tr>
              <th {...thProps("name")}>Name</th>
              <th {...thProps("promotion")}>Promotion</th>
              <th {...thProps("date")}>Date</th>
              <th />
            </tr>
          </thead>

          <tbody>
            {visibleItems.map((affiliateRequest) => (
              <tr key={affiliateRequest.id}>
                <td>
                  {affiliateRequest.name}
                  <small>{affiliateRequest.email}</small>
                </td>

                <td data-label="Promotion">{affiliateRequest.promotion}</td>

                <td data-label="Date">{parseISO(affiliateRequest.date).toLocaleDateString(userAgentInfo.locale)}</td>

                <td>
                  <div className="actions">
                    <Button
                      disabled={
                        !loggedInUser?.policies.direct_affiliate.update ||
                        isLoading ||
                        !!affiliateRequest.processingState
                      }
                      onClick={() => update(affiliateRequest, "ignore")}
                    >
                      {affiliateRequest.processingState === "ignore" ? "Ignoring" : "Ignore"}
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
                        onClick={() => update(affiliateRequest, "approve")}
                        disabled={
                          !loggedInUser?.policies.direct_affiliate.update ||
                          isLoading ||
                          affiliateRequest.state === "approved" ||
                          !!affiliateRequest.processingState
                        }
                      >
                        {affiliateRequest.state === "approved"
                          ? "Approved"
                          : affiliateRequest.processingState === "approve"
                            ? "Approving"
                            : "Approve"}
                      </Button>
                    </WithTooltip>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : (
        <div className="placeholder">No requests yet</div>
      )}

      {showMoreItems ? <Button onClick={showMoreItems}>Load more</Button> : null}
    </>
  );
};

const formattedSalesVolumeAmount = (amountCents: number) =>
  formatPriceCentsWithCurrencySymbol("usd", amountCents, { symbolFormat: "short" });

export type SortKey = "affiliate_user_name" | "products" | "fee_percent" | "volume_cents";
export type Params = {
  page: number | null;
  query: string | null;
  sort: Sort<SortKey> | null;
};

const AffiliatesTab = () => {
  const navigation = useNavigation();
  const revalidator = useRevalidator();
  const loggedInUser = useLoggedInUser();
  const [searchParams, setSearchParams] = useSearchParams();

  const data = cast<PagedAffiliatesData>(useLoaderData());
  const [affiliateRequests] = React.useState(data.affiliate_requests);
  const { allow_approve_all_requests: allowApproveAllRequests, affiliates, pagination } = data;
  const [selectedAffiliate, setSelectedAffiliate] = React.useState<Affiliate | null>(null);
  const [sort, setSort] = React.useState<Sort<SortKey> | null>(null);
  const searchQuery = searchParams.get("query") ?? "";

  const onSearch = useDebouncedCallback((newQuery: string) => {
    if (searchParams.get("query") === newQuery) return;

    setSearchParams((prevState) => {
      const params = new URLSearchParams(prevState);
      if (newQuery.length > 0) {
        params.set("query", newQuery);
      } else {
        params.delete("query");
      }
      params.delete("page");
      return params;
    });
  }, 500);

  const onChangePage = (newPage: number) => {
    setSearchParams((prevState) => {
      const params = new URLSearchParams(prevState);
      params.set("page", newPage.toString());
      return params;
    });
  };

  const onSetSort = (newSort: Sort<SortKey> | null) => {
    setSearchParams((prevState) => {
      const params = new URLSearchParams(prevState);
      if (pagination.pages > 1) params.set("page", "1");
      if (newSort) {
        params.set("column", newSort.key);
        params.set("sort", newSort.direction);
      }
      return params;
    });
    setSort(newSort);
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

  const remove = asyncVoid(async (affiliateId: string) => {
    try {
      await removeAffiliate(affiliateId);
      if (selectedAffiliate) setSelectedAffiliate(null);
      revalidator.revalidate();
      showAlert("The affiliate was removed successfully.", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Failed to remove the affiliate.", "error");
    }
  });

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
          showAlert(err.message, "error");
          affiliateStatisticsRequests.current.delete(id);
        },
      );
    }
  }, [affiliates]);

  return (
    <Layout
      title="Affiliates"
      actions={
        <>
          <SearchBoxPopover onSearch={onSearch} initialQuery={searchQuery} />
          <WithTooltip position="bottom" tip={data.affiliates_disabled_reason}>
            <Link
              to="/affiliates/new"
              className="button accent"
              inert={!loggedInUser?.policies.direct_affiliate.create}
              style={
                data.affiliates_disabled_reason !== null
                  ? { pointerEvents: "none", cursor: "not-allowed", opacity: 0.3 }
                  : undefined
              }
            >
              Add affiliate
            </Link>
          </WithTooltip>
        </>
      }
      navigation={<AffiliatesNavigation />}
    >
      <div className="p-4 lg:p-8" style={{ display: "grid", gap: "var(--spacer-7)" }}>
        {navigation.state === "loading" && affiliates.length === 0 ? (
          <div style={{ justifySelf: "center" }}>
            <Progress width="5rem" />
          </div>
        ) : (
          <>
            {affiliateRequests.length > 0 && !searchQuery && pagination.page === 1 ? (
              <AffiliateRequestsTable affiliateRequests={affiliateRequests} allowApproveAll={allowApproveAllRequests} />
            ) : null}
            {affiliates.length > 0 ? (
              <>
                <section className="paragraphs">
                  <table aria-busy={navigation.state !== "idle"}>
                    <caption>
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
                    </caption>
                    <thead>
                      <tr>
                        <th {...thProps("affiliate_user_name")}>Name</th>
                        <th {...thProps("products")}>Products</th>
                        <th {...thProps("fee_percent")}>Commission</th>
                        <th {...thProps("volume_cents")}>Sales</th>
                        <th />
                      </tr>
                    </thead>

                    <tbody>
                      {affiliates.map((affiliate) => {
                        const enabledProducts = affiliate.products;
                        const statistics = affiliateStatistics[affiliate.id];

                        return (
                          <tr
                            key={affiliate.id}
                            aria-selected={affiliate.id === selectedAffiliate?.id}
                            onClick={() => setSelectedAffiliate(affiliate)}
                          >
                            <td data-label="Name">{affiliate.affiliate_user_name}</td>
                            <td data-label="Products">
                              <WithTooltip
                                tip={enabledProducts.length <= 1 ? null : productTooltipLabel(enabledProducts)}
                              >
                                <a href={affiliate.product_referral_url} onClick={(e) => e.stopPropagation()}>
                                  {productName(enabledProducts)}
                                </a>
                              </WithTooltip>
                            </td>
                            <td data-label="Commission">{formattedFeePercentLabel(affiliate)}</td>
                            {statistics ? (
                              <td data-label="Sales">{formattedSalesVolumeAmount(statistics.total_volume_cents)}</td>
                            ) : (
                              <td aria-busy data-label="Sales" />
                            )}
                            <td>
                              <div className="actions" onClick={(e) => e.stopPropagation()}>
                                <CopyToClipboard
                                  tooltipPosition="bottom"
                                  copyTooltip="Copy link"
                                  text={affiliate.product_referral_url}
                                >
                                  <Button>Copy link</Button>
                                </CopyToClipboard>

                                <Link
                                  to={`/affiliates/${affiliate.id}/edit`}
                                  className="button"
                                  aria-label="Edit"
                                  inert={!loggedInUser?.policies.direct_affiliate.update || navigation.state !== "idle"}
                                >
                                  <Icon name="pencil" />
                                </Link>

                                <Button
                                  type="submit"
                                  color="danger"
                                  onClick={() => remove(affiliate.id)}
                                  aria-label="Delete"
                                  disabled={
                                    !loggedInUser?.policies.direct_affiliate.update || navigation.state !== "idle"
                                  }
                                >
                                  <Icon name="trash2" />
                                </Button>
                              </div>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                  {pagination.pages > 1 ? <Pagination onChangePage={onChangePage} pagination={pagination} /> : null}
                </section>
                {selectedAffiliate ? (
                  <AffiliateDetails
                    selectedAffiliate={selectedAffiliate}
                    statistics={affiliateStatistics[selectedAffiliate.id]}
                    onClose={() => setSelectedAffiliate(null)}
                    onRemove={remove}
                  />
                ) : null}
              </>
            ) : (
              <div className="placeholder">
                <figure>
                  <img src={placeholder} />
                </figure>
                <h2>No affiliates found</h2>
              </div>
            )}
          </>
        )}
      </div>
    </Layout>
  );
};

const AffiliateDetails = ({
  selectedAffiliate,
  statistics,
  onClose,
  onRemove,
}: {
  selectedAffiliate: Affiliate;
  statistics: AffiliateStatistics | undefined;
  onClose: () => void;
  onRemove: (id: string) => void;
}) => {
  const loggedInUser = useLoggedInUser();
  const navigation = useNavigation();

  return ReactDOM.createPortal(
    <aside>
      <header>
        <h2>{selectedAffiliate.affiliate_user_name}</h2>
        <button className="close" aria-label="Close" onClick={onClose} />
      </header>
      {selectedAffiliate.products.map((product) => {
        const productStatistics = statistics?.products[product.id];

        return (
          <section key={product.id} className="stack">
            <h3>{product.name}</h3>
            {statistics ? (
              <>
                <div>
                  <h5>Revenue</h5>
                  {formattedSalesVolumeAmount(productStatistics?.volume_cents ?? 0)}
                </div>
                <div>
                  <h5>Sales</h5>
                  {productStatistics?.sales_count ?? 0}
                </div>
              </>
            ) : null}
            <div>
              <h5>Commission</h5>
              {((product.fee_percent ?? 0) / 100).toLocaleString([], { style: "percent" })}
            </div>
            <div>
              <CopyToClipboard tooltipPosition="bottom" copyTooltip="Copy link" text={product.referral_url}>
                <Button>Copy link</Button>
              </CopyToClipboard>
            </div>
          </section>
        );
      })}
      <section style={{ display: "grid", gap: "var(--spacer-4)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
        <Link
          to={`/affiliates/${selectedAffiliate.id}/edit`}
          className="button"
          aria-label="Edit"
          inert={!loggedInUser?.policies.direct_affiliate.update || navigation.state !== "idle"}
        >
          Edit
        </Link>
        <Button
          color="danger"
          aria-label="Delete"
          onClick={() => onRemove(selectedAffiliate.id)}
          disabled={!loggedInUser?.policies.direct_affiliate.update || navigation.state !== "idle"}
        >
          {navigation.state === "submitting" ? "Deleting..." : "Delete"}
        </Button>
      </section>
    </aside>,
    document.body,
  );
};

type FormProps = {
  title: string;
  headerLabel: string;
  submitLabel: string;
};

const Form = ({ title, headerLabel, submitLabel }: FormProps) => {
  const affiliate = cast<AffiliateRequestPayload>(useLoaderData());
  const loggedInUser = useLoggedInUser();
  const navigate = useNavigate();
  const navigation = useNavigation();
  const { affiliateId } = useParams();
  const [errors, setErrors] = React.useState<Map<string, string>>(new Map());
  const [affiliateState, setAffiliateState] = React.useState<AffiliateRequestPayload>(affiliate);

  const uid = React.useId();
  const emailInputRef = React.useRef<HTMLInputElement>(null);
  const canSave = affiliateId
    ? loggedInUser?.policies.direct_affiliate.update
    : loggedInUser?.policies.direct_affiliate.create;

  const toggleAllProducts = (allProducts: boolean) => {
    if (allProducts) {
      setAffiliateState({
        ...affiliateState,
        apply_to_all_products: allProducts,
        products: affiliateState.products.map((product) => ({
          ...product,
          enabled: true,
          fee_percent: affiliateState.fee_percent,
        })),
      });
    } else {
      setAffiliateState({
        ...affiliateState,
        apply_to_all_products: allProducts,
        products: affiliateState.products.map((product) => ({ ...product, enabled: false })),
      });
    }
  };

  const getValidationErrors = () => {
    const { email, fee_percent, products, apply_to_all_products, destination_url } = affiliateState;
    const errors = new Map<string, string>();

    if (email.length === 0) {
      errors.set("email", "Email is required");
    } else if (!isValidEmail(email)) {
      errors.set("email", "Please enter a valid email address");
    }

    if (apply_to_all_products && (!fee_percent || fee_percent < 1 || fee_percent > 90)) {
      errors.set("feePercent", "Commission must be between 1% and 90%");
    }

    if (
      !apply_to_all_products &&
      products.some(
        (product) => product.enabled && (!product.fee_percent || product.fee_percent < 1 || product.fee_percent > 90),
      )
    ) {
      errors.set("products", "All enabled products must have commission between 1% and 90%");
    }

    if (destination_url && destination_url !== "" && !isUrlValid(destination_url)) {
      errors.set("destinationUrl", "Please enter a valid URL");
    }

    return errors;
  };

  const handleValidationErrors = (errors: Map<string, string>) => {
    setErrors(errors);

    if (errors.size > 0) {
      const [firstErrorType, firstErrorMessage] = Array.from(errors.entries())[0] || [
        "error",
        "Please fill all required fields",
      ];
      if (firstErrorMessage) showAlert(firstErrorMessage, "error");
      if (firstErrorType === "email" && emailInputRef.current) emailInputRef.current.focus();
    }
  };

  const handleSubmit = asyncVoid(async () => {
    const { apply_to_all_products, products } = affiliateState;
    const errors = getValidationErrors();

    if (errors.size > 0) {
      handleValidationErrors(errors);
      return;
    }

    if (!apply_to_all_products && products.every((product) => !product.enabled)) {
      showAlert("Please enable at least one product.", "error");
      return;
    }

    try {
      await ("id" in affiliateState ? updateAffiliate(affiliateState) : addAffiliate(affiliateState));
      showAlert("Changes saved!", "success");
      navigate("/affiliates");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  React.useEffect(() => {
    if (affiliateState.products.length > 0) {
      setAffiliateState({
        ...affiliateState,
        apply_to_all_products: affiliateState.products.every(
          (product) => product.enabled && product.fee_percent === affiliateState.fee_percent,
        ),
      });
    }
  }, [affiliateState.products]);

  const handleEmailChange = (evt: React.ChangeEvent<HTMLInputElement>) => {
    setAffiliateState({ ...affiliateState, email: evt.target.value });
    if (errors.has("email")) {
      const newErrors = new Map(errors);
      newErrors.delete("email");
      setErrors(newErrors);
    }
  };

  return (
    <Layout
      title={title}
      actions={
        <>
          <Link to="/affiliates" className="button" inert={navigation.state !== "idle"}>
            <Icon name="x-square" />
            Cancel
          </Link>
          <Button color="accent" onClick={handleSubmit} disabled={navigation.state !== "idle" || !canSave}>
            {submitLabel}
          </Button>
        </>
      }
      hasStickyHeader
    >
      <form>
        <section className="!p-4 md:!p-8">
          <header dangerouslySetInnerHTML={{ __html: headerLabel }} />
          <fieldset className={cx({ danger: errors.has("email") })}>
            <legend>
              <label htmlFor={`${uid}email`}>Email</label>
            </legend>
            <input
              ref={emailInputRef}
              type="email"
              id={`${uid}email`}
              placeholder="Email of a Gumroad creator"
              value={affiliateState.email}
              disabled={!!affiliateId || navigation.state !== "idle"}
              aria-invalid={errors.has("email")}
              onChange={handleEmailChange}
              autoFocus={!affiliateId}
            />
          </fieldset>
          <table>
            <thead>
              <tr>
                <th>Enable</th>
                <th>Product</th>
                <th>Commission</th>
                <th>
                  <a href="/help/article/333-affiliates-on-gumroad" target="_blank" rel="noreferrer">
                    Destination URL (optional)
                  </a>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td data-label="Enable">
                  <input
                    id={`${uid}enableAllProducts`}
                    type="checkbox"
                    role="switch"
                    checked={affiliateState.apply_to_all_products}
                    onChange={(evt) => toggleAllProducts(evt.target.checked)}
                    aria-label="Enable all products"
                  />
                </td>
                <td data-label="Product">
                  <label htmlFor={`${uid}enableAllProducts`}>All products</label>
                </td>
                <td data-label="Commission">
                  <fieldset className={cx({ danger: errors.has("feePercent") })}>
                    <NumberInput
                      onChange={(value) =>
                        setAffiliateState({
                          ...affiliateState,
                          fee_percent: value,
                          products: affiliateState.products.map((product) => ({
                            ...product,
                            fee_percent: value,
                          })),
                        })
                      }
                      value={affiliateState.fee_percent}
                    >
                      {(inputProps) => (
                        <div
                          className={cx("input", {
                            disabled: navigation.state !== "idle" || !affiliateState.apply_to_all_products,
                          })}
                        >
                          <input
                            type="text"
                            autoComplete="off"
                            placeholder="Commission"
                            disabled={navigation.state === "submitting" || !affiliateState.apply_to_all_products}
                            {...inputProps}
                          />
                          <div className="pill">%</div>
                        </div>
                      )}
                    </NumberInput>
                  </fieldset>
                </td>
                <td>
                  <fieldset className={cx({ danger: errors.has("destinationUrl") })}>
                    <input
                      type="url"
                      value={affiliateState.destination_url || ""}
                      placeholder="https://link.com"
                      onChange={(evt) => setAffiliateState({ ...affiliateState, destination_url: evt.target.value })}
                      disabled={navigation.state !== "idle" || !affiliateState.apply_to_all_products}
                    />
                  </fieldset>
                </td>
              </tr>
              {affiliateState.products.map((product) => (
                <ProductRow
                  key={product.id}
                  product={product}
                  disabled={!canSave}
                  onChange={(value) =>
                    setAffiliateState({
                      ...affiliateState,
                      products: affiliateState.products.map((affiliateProduct) =>
                        affiliateProduct.id === product.id ? { ...affiliateProduct, ...value } : affiliateProduct,
                      ),
                    })
                  }
                />
              ))}
            </tbody>
          </table>
        </section>
      </form>
    </Layout>
  );
};

const routes: RouteObject[] = [
  {
    path: "/affiliates",
    element: <AffiliatesTab />,
    loader: async ({ request }) => {
      const url = new URL(request.url);
      const page = url.searchParams.get("page");
      const query = url.searchParams.get("query") ?? null;
      const data = await getPagedAffiliates({
        page: page ? parseInt(page, 10) : 1,
        query,
        sort: extractSortParam(url.searchParams),
        // Only fetch affiliate requests on initial page load (via SSR or react-router navigation)
        shouldGetAffiliateRequests: SSR || request.url.endsWith("/affiliates"),
        abortSignal: request.signal,
      });
      if (data.affiliates.length === 0 && data.affiliate_requests.length === 0 && !page && !query) {
        return redirect("/affiliates/onboarding");
      }
      return data;
    },
  },
  {
    path: "affiliates/onboarding",
    element: <AffiliateSignupForm />,
    loader: getOnboardingAffiliateData,
  },
  {
    path: "affiliates/new",
    element: (
      <Form
        title="New Affiliate"
        headerLabel="Add a new affiliate below and we'll send them a unique link to share with their audience. Your affiliate will then earn a commission on each sale they refer. <a href='/help/article/333-affiliates-on-gumroad' target='_blank' rel='noreferrer'>Learn more</a>"
        submitLabel="Add affiliate"
      />
    ),
    loader: async () => {
      const { products } = await getOnboardingAffiliateData();
      const response = {
        email: "",
        products: products.map((product) => ({
          id: product.id,
          enabled: false,
          name: product.name,
          fee_percent: null,
          referral_url: "",
          destination_url: null,
        })),
        apply_to_all_products: products.length === 0,
        fee_percent: null,
        destination_url: null,
      };
      return json(response, { status: 200 });
    },
  },
  {
    path: "affiliates/:affiliateId/edit",
    element: (
      <Form
        title="Edit Affiliate"
        headerLabel="The process of editing is almost identical to adding them. You can change their affiliate fee, the products they are assigned. Their affiliate link will not change. <a href='/help/article/333-affiliates-on-gumroad' target='_blank' rel='noreferrer'>Learn more</a>"
        submitLabel="Save changes"
      />
    ),
    loader: async ({ params }) => {
      const affiliate = await loadAffiliate(assertDefined(params.affiliateId, "Affiliate ID is required"));
      if (!affiliate) return redirect("/affiliates");

      const response = {
        ...affiliate,
        apply_to_all_products: affiliate.products.every(
          (product) => product.enabled && product.fee_percent === affiliate.fee_percent,
        ),
      };
      return json(response);
    },
  },
];

const AffiliatesPage = () => {
  const router = createBrowserRouter(routes);

  return <RouterProvider router={router} />;
};

const AffiliatesRouter = async (global: GlobalProps) => {
  const { router, context } = await buildStaticRouter(global, routes);
  const component = () => <StaticRouterProvider router={router} context={context} nonce={global.csp_nonce} />;
  component.displayName = "AffiliatesRouter";
  return component;
};

export default register({ component: AffiliatesPage, ssrComponent: AffiliatesRouter, propParser: () => ({}) });
