import { Link, Trash, XCircle } from "@boxicons/react";
import * as React from "react";

import {
  AffiliationAlreadyRemovedError,
  getPagedAffiliatedProducts,
  removeSelfAsAffiliate,
} from "$app/data/affiliated_products";
import { classNames } from "$app/utils/classNames";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { GlobalAffiliates } from "$app/components/GlobalAffiliates";
import { Modal } from "$app/components/Modal";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { ProductsLayout } from "$app/components/ProductsLayout";
import { Search } from "$app/components/Search";
import { showAlert } from "$app/components/server-components/Alert";
import { Stats as StatsComponent } from "$app/components/Stats";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { Sort, useSortingTableDriver } from "$app/components/useSortingTableDriver";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/affiliated.png";

export type AffiliatedProduct = {
  product_name: string;
  url: string;
  fee_percentage: number;
  revenue: number;
  humanized_revenue: string;
  sales_count: number;
  affiliate_type: "direct_affiliate" | "global_affiliate";
  affiliate_id: string | null;
  seller_name: string | null;
};

export type AffiliatedPageStats = {
  total_revenue: number;
  total_sales: number;
  total_products: number;
  total_affiliated_creators: number;
};

export type AffiliatedPageProps = {
  pagination: PaginationProps;
  affiliated_products: AffiliatedProduct[];
  stats: AffiliatedPageStats;
  global_affiliates_data: {
    global_affiliate_id: number | null;
    global_affiliate_sales: string | null;
    cookie_expiry_days: number;
    affiliate_query_param: string;
  };
  archived_tab_visible: boolean;
  affiliates_disabled_reason: string | null;
};

const StatsSection = (stats: AffiliatedPageStats) => {
  const { locale } = useUserAgentInfo();

  return (
    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4" aria-label="Stats">
      <StatsComponent
        title="Revenue"
        description="Your gross sales from all affiliated products."
        value={formatPriceCentsWithCurrencySymbol("usd", stats.total_revenue, { symbolFormat: "short" })}
      />
      <StatsComponent
        title="Sales"
        description="Your number of affiliated sales."
        value={stats.total_sales.toLocaleString(locale)}
      />
      <StatsComponent
        title="Products"
        description="Your number of affiliated products."
        value={stats.total_products.toLocaleString(locale)}
      />
      <StatsComponent
        title="Affiliated creators"
        description="The number of creators you're affiliated with."
        value={stats.total_affiliated_creators.toLocaleString(locale)}
      />
    </div>
  );
};

type AffiliatedProductsTableProps = {
  affiliatedProducts: AffiliatedProduct[];
  pagination: PaginationProps;
  loadAffiliatedProducts: (page: number, sort: Sort<SortKey> | null) => void;
  onAffiliationRemoved: (data: {
    affiliatedProducts: AffiliatedProduct[];
    pagination: PaginationProps;
    stats: AffiliatedPageStats;
  }) => void;
  query: string;
  cancelPendingLoad: () => void;
  isLoading: boolean;
};

export type SortKey = "product_name" | "sales_count" | "commission" | "revenue";

const AffiliatedProductsTable = ({
  affiliatedProducts,
  pagination,
  loadAffiliatedProducts,
  onAffiliationRemoved,
  query,
  cancelPendingLoad,
  isLoading,
}: AffiliatedProductsTableProps) => {
  const [sort, setSort] = React.useState<Sort<SortKey> | null>(null);
  const thProps = useSortingTableDriver<SortKey>(sort, setSort);
  const userAgentInfo = useUserAgentInfo();
  const [removing, setRemoving] = React.useState<{ product: AffiliatedProduct; inFlight: boolean } | null>(null);

  React.useEffect(() => {
    if (sort) loadAffiliatedProducts(1, sort);
  }, [sort]);

  const removeAffiliation = async (product: AffiliatedProduct) => {
    if (product.affiliate_id === null) return;
    try {
      // A search or sort GET still in flight would resolve after this and repaint the removed rows
      // back in.
      cancelPendingLoad();
      setRemoving({ product, inFlight: true });
      const {
        affiliated_products: affiliatedProducts,
        pagination,
        stats,
      } = await removeSelfAsAffiliate(product.affiliate_id, { query, sort });
      setRemoving(null);
      onAffiliationRemoved({ affiliatedProducts, pagination, stats });
      showAlert("You're no longer an affiliate for these products.", "success");
    } catch (e) {
      assertResponseError(e);
      // The row is stale — the affiliation went away in another tab. Retrying would 404 forever, so
      // close the dialog and reload instead of leaving a dead row behind a retry prompt.
      if (e instanceof AffiliationAlreadyRemovedError) {
        setRemoving(null);
        showAlert(e.message, "error");
        loadAffiliatedProducts(pagination.page, sort);
        return;
      }
      setRemoving({ product, inFlight: false });
      showAlert(e.message, "error");
    }
  };

  return (
    <section className="flex flex-col gap-4">
      <Table aria-live="polite" className={classNames(isLoading && "pointer-events-none opacity-50")}>
        <TableHeader>
          <TableRow>
            <TableHead {...thProps("product_name")} title="Sort by Product">
              Product
            </TableHead>
            <TableHead {...thProps("sales_count")} title="Sort by Sales">
              Sales
            </TableHead>
            <TableHead title="Sort by Type">Type</TableHead>
            <TableHead {...thProps("commission")} title="Sort by Commission">
              Commission
            </TableHead>
            <TableHead {...thProps("revenue")} title="Sort by Revenue">
              Revenue
            </TableHead>
            <TableHead />
          </TableRow>
        </TableHeader>

        <TableBody>
          {affiliatedProducts.map((affiliatedProduct) => (
            <TableRow key={affiliatedProduct.url}>
              <TableCell>
                <a href={affiliatedProduct.url} title={affiliatedProduct.url} target="_blank" rel="noreferrer">
                  {affiliatedProduct.product_name}
                </a>
              </TableCell>

              <TableCell className="whitespace-nowrap">
                {affiliatedProduct.sales_count.toLocaleString(userAgentInfo.locale)}
              </TableCell>

              <TableCell className="whitespace-nowrap">
                {affiliatedProduct.affiliate_type === "direct_affiliate" ? "Direct" : "Gumroad"}
              </TableCell>

              <TableCell>{(affiliatedProduct.fee_percentage / 100).toLocaleString([], { style: "percent" })}</TableCell>

              <TableCell className="whitespace-nowrap">{affiliatedProduct.humanized_revenue}</TableCell>

              <TableCell>
                <div className="flex flex-wrap gap-3 lg:justify-end">
                  <CopyToClipboard tooltipPosition="bottom" copyTooltip="Copy link" text={affiliatedProduct.url}>
                    <Button>
                      <Link className="size-5" />
                      Copy link
                    </Button>
                  </CopyToClipboard>
                  {/* nil affiliate_id means either a Gumroad Affiliates row or a viewer role that
                      cannot end affiliations, so the control simply does not exist for them. */}
                  {affiliatedProduct.affiliate_id !== null ? (
                    <Button
                      aria-label={`Remove yourself as an affiliate for ${affiliatedProduct.product_name}`}
                      onClick={() => setRemoving({ product: affiliatedProduct, inFlight: false })}
                    >
                      <Trash className="size-5" />
                      Remove
                    </Button>
                  ) : null}
                </div>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
      {removing ? (
        <Modal
          open
          allowClose={!removing.inFlight}
          onClose={() => setRemoving(null)}
          title="Remove yourself as an affiliate?"
          footer={
            <>
              <Button disabled={removing.inFlight} onClick={() => setRemoving(null)}>
                Cancel
              </Button>
              <Button
                color="danger"
                disabled={removing.inFlight}
                onClick={asyncVoid(() => removeAffiliation(removing.product))}
              >
                {removing.inFlight ? "Removing..." : "Yes, remove me"}
              </Button>
            </>
          }
        >
          <p>
            You will stop earning commission on{" "}
            {removing.product.seller_name === null ? "this seller's" : `${removing.product.seller_name}'s`} products,
            and your existing affiliate links for them will stop crediting you. Commission you have already earned is
            not affected.
          </p>
        </Modal>
      ) : null}
      {pagination.pages > 1 ? (
        <Pagination onChangePage={(page) => loadAffiliatedProducts(page, sort)} pagination={pagination} />
      ) : null}
    </section>
  );
};

type AffiliatedPageState = {
  affiliatedProducts: AffiliatedProduct[];
  pagination: PaginationProps;
  stats: AffiliatedPageStats;
  query: string;
};

const AffiliatedPage = ({
  affiliated_products: initialAffiliatedProducts,
  stats: initialStats,
  global_affiliates_data: globalAffiliatesData,
  archived_tab_visible: archivedTabVisible,
  pagination: initialPaginationState,
  affiliates_disabled_reason: affiliatesDisabledReason,
}: AffiliatedPageProps) => {
  const url = new URL(useOriginalLocation());
  const [isShowingGlobalAffiliates, setIsShowingGlobalAffiliates] = React.useState(
    url.searchParams.get("affiliates") === "true",
  );

  useGlobalEventListener("popstate", () => {
    setIsShowingGlobalAffiliates(new URL(location.href).searchParams.get("affiliates") === "true");
  });

  const [state, setState] = React.useState<AffiliatedPageState>({
    pagination: initialPaginationState,
    affiliatedProducts: initialAffiliatedProducts,
    stats: initialStats,
    query: "",
  });
  const { affiliatedProducts, pagination, stats } = state;
  const [isLoading, setIsLoading] = React.useState(false);
  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);

  const loadAffiliatedProducts = async (page: number, query?: string, sort?: Sort<SortKey> | null) => {
    try {
      activeRequest.current?.cancel();
      setIsLoading(true);
      const request = getPagedAffiliatedProducts(page, query, sort);
      activeRequest.current = request;

      const { affiliated_products: affiliatedProducts, pagination } = await request.response;
      setState((prevState) => ({ ...prevState, affiliatedProducts, pagination }));
      setIsLoading(false);
      activeRequest.current = null;
    } catch (e) {
      // A cancellation means a newer load (or a removal) owns the table now and will settle the
      // loading state itself. Any other failure has to clear it here, or the table stays dimmed and
      // unusable with nothing in flight.
      if (e instanceof AbortError) return;
      setIsLoading(false);
      activeRequest.current = null;
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };
  const debouncedLoadAffiliatedProducts = useDebouncedCallback(asyncVoid(loadAffiliatedProducts), 500);

  const handleSearch = (query: string) => {
    if (query === state.query) return;
    setState((prevState) => ({ ...prevState, query }));
    debouncedLoadAffiliatedProducts(state.pagination.page, query);
  };

  const toggleOpen = (newState: boolean) => {
    setIsShowingGlobalAffiliates(newState);
    const url = new URL(window.location.href);
    url.searchParams.set("affiliates", newState.toString());
    window.history.pushState({}, "", url);
  };

  return (
    <ProductsLayout
      selectedTab="affiliated"
      title={isShowingGlobalAffiliates ? "Gumroad Affiliates" : undefined}
      ctaButton={
        isShowingGlobalAffiliates ? (
          <Button onClick={() => toggleOpen(false)}>
            <XCircle className="size-5" />
            Close
          </Button>
        ) : (
          <>
            {initialAffiliatedProducts.length > 0 && <Search onSearch={handleSearch} value={state.query} />}
            <WithTooltip position="bottom" tip={affiliatesDisabledReason}>
              <Button color="accent" disabled={affiliatesDisabledReason !== null} onClick={() => toggleOpen(true)}>
                Gumroad affiliate
              </Button>
            </WithTooltip>
          </>
        )
      }
      archivedTabVisible={archivedTabVisible}
    >
      {isShowingGlobalAffiliates && globalAffiliatesData.global_affiliate_id != null ? (
        <GlobalAffiliates
          globalAffiliateId={globalAffiliatesData.global_affiliate_id}
          totalSales={globalAffiliatesData.global_affiliate_sales}
          cookieExpiryDays={globalAffiliatesData.cookie_expiry_days}
          affiliateQueryParam={globalAffiliatesData.affiliate_query_param}
        />
      ) : (
        <section className="p-4 md:p-8">
          {initialAffiliatedProducts.length === 0 ? (
            <Placeholder>
              <PlaceholderImage src={placeholder} />
              <h2>Become an affiliate and earn!</h2>
              Gumroad is a great place for you to make some side income, even if you're not actively creating your own
              products.
              <WithTooltip position="top" tip={affiliatesDisabledReason}>
                <Button disabled={affiliatesDisabledReason !== null} color="accent" onClick={() => toggleOpen(true)}>
                  Become an affiliate
                </Button>
              </WithTooltip>
              <p>
                or{" "}
                <a href="/help/article/249-affiliate-faq" target="_blank" rel="noreferrer">
                  learn more to get started
                </a>
              </p>
            </Placeholder>
          ) : (
            <div style={{ display: "grid", gap: "var(--spacer-7)" }}>
              <StatsSection {...stats} />
              {state.affiliatedProducts.length === 0 ? (
                <Placeholder>
                  <PlaceholderImage src={placeholder} />
                  <h2>No affiliated products found.</h2>
                </Placeholder>
              ) : (
                <AffiliatedProductsTable
                  affiliatedProducts={affiliatedProducts}
                  pagination={pagination}
                  loadAffiliatedProducts={(page: number, sort: Sort<SortKey> | null) => {
                    void loadAffiliatedProducts(page, state.query, sort);
                  }}
                  onAffiliationRemoved={({ affiliatedProducts, pagination, stats }) =>
                    setState((prevState) => ({ ...prevState, affiliatedProducts, pagination, stats }))
                  }
                  query={state.query}
                  cancelPendingLoad={() => {
                    debouncedLoadAffiliatedProducts.cancel();
                    activeRequest.current?.cancel();
                    activeRequest.current = null;
                    // Nothing follows this cancellation to settle the loader — the cancelled load's
                    // own catch returns early precisely because a newer load usually owns the state.
                    setIsLoading(false);
                  }}
                  isLoading={isLoading}
                />
              )}
            </div>
          )}
        </section>
      )}
    </ProductsLayout>
  );
};

export default AffiliatedPage;
