import * as React from "react";
import { createCast } from "ts-safe-cast";

import { getPagedAffiliatedProducts } from "$app/data/affiliated_products";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { AbortError, assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { GlobalAffiliates } from "$app/components/GlobalAffiliates";
import { Icon } from "$app/components/Icons";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Popover } from "$app/components/Popover";
import { ProductsLayout } from "$app/components/ProductsLayout";
import { showAlert } from "$app/components/server-components/Alert";
import { Stats as StatsComponent } from "$app/components/Stats";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { Sort, useSortingTableDriver } from "$app/components/useSortingTableDriver";
import { WithTooltip } from "$app/components/WithTooltip";

import { useGlobalEventListener } from "../useGlobalEventListener";

import placeholder from "$assets/images/placeholders/affiliated.png";

export type AffiliatedProduct = {
  product_name: string;
  url: string;
  fee_percentage: number;
  revenue: number;
  humanized_revenue: string;
  sales_count: number;
  affiliate_type: "direct_affiliate" | "global_affiliate";
};

type Stats = {
  total_revenue: number;
  total_sales: number;
  total_products: number;
  total_affiliated_creators: number;
};

type Props = {
  pagination: PaginationProps;
  affiliated_products: AffiliatedProduct[];
  stats: Stats;
  global_affiliates_data: {
    global_affiliate_id: number;
    global_affiliate_sales: string;
    cookie_expiry_days: number;
    affiliate_query_param: string;
  };
  archived_tab_visible: boolean;
  affiliates_disabled_reason: string | null;
};

const StatsSection = (stats: Stats) => {
  const { locale } = useUserAgentInfo();

  return (
    <div className="stats-grid" aria-label="Stats">
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
  isLoading: boolean;
};

export type SortKey = "product_name" | "sales_count" | "commission" | "revenue";

const AffiliatedProductsTable = ({
  affiliatedProducts,
  pagination,
  loadAffiliatedProducts,
  isLoading,
}: AffiliatedProductsTableProps) => {
  const [sort, setSort] = React.useState<Sort<SortKey> | null>(null);
  const thProps = useSortingTableDriver<SortKey>(sort, setSort);
  const userAgentInfo = useUserAgentInfo();

  React.useEffect(() => {
    if (sort) loadAffiliatedProducts(1, sort);
  }, [sort]);

  return (
    <section className="paragraphs">
      <table aria-live="polite" aria-busy={isLoading}>
        <thead>
          <tr>
            <th {...thProps("product_name")} title="Sort by Product">
              Product
            </th>
            <th {...thProps("sales_count")} title="Sort by Sales">
              Sales
            </th>
            <th title="Sort by Type">Type</th>
            <th {...thProps("commission")} title="Sort by Commission">
              Commission
            </th>
            <th {...thProps("revenue")} title="Sort by Revenue">
              Revenue
            </th>
            <th />
          </tr>
        </thead>

        <tbody>
          {affiliatedProducts.map((affiliatedProduct) => (
            <tr key={affiliatedProduct.url}>
              <td>
                <a href={affiliatedProduct.url} title={affiliatedProduct.url} target="_blank" rel="noreferrer">
                  {affiliatedProduct.product_name}
                </a>
              </td>

              <td data-label="Sales" style={{ whiteSpace: "nowrap" }}>
                {affiliatedProduct.sales_count.toLocaleString(userAgentInfo.locale)}
              </td>

              <td data-label="Type" style={{ whiteSpace: "nowrap" }}>
                {affiliatedProduct.affiliate_type === "direct_affiliate" ? "Direct" : "Gumroad"}
              </td>

              <td data-label="Commission">
                {(affiliatedProduct.fee_percentage / 100).toLocaleString([], { style: "percent" })}
              </td>

              <td data-label="Revenue" style={{ whiteSpace: "nowrap" }}>
                {affiliatedProduct.humanized_revenue}
              </td>

              <td>
                <div className="actions">
                  <CopyToClipboard tooltipPosition="bottom" copyTooltip="Copy link" text={affiliatedProduct.url}>
                    <Button>
                      <Icon name="link" />
                      Copy link
                    </Button>
                  </CopyToClipboard>
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {pagination.pages > 1 ? (
        <Pagination onChangePage={(page) => loadAffiliatedProducts(page, sort)} pagination={pagination} />
      ) : null}
    </section>
  );
};

type SearchProps = {
  onSearch: (query: string) => void;
  value: string;
};

const Search = ({ onSearch, value }: SearchProps) => {
  const [open, setOpen] = React.useState(false);
  const searchInputRef = React.useRef<HTMLInputElement>(null);

  React.useEffect(() => {
    if (open) searchInputRef.current?.focus();
  }, [open]);

  return (
    <Popover
      open={open}
      onToggle={setOpen}
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
          value={value}
          autoFocus
          type="text"
          placeholder="Search"
          onChange={(e) => onSearch(e.target.value)}
        />
      </div>
    </Popover>
  );
};

type AffiliatedPageState = {
  affiliatedProducts: AffiliatedProduct[];
  pagination: PaginationProps;
  query: string;
};

const AffiliatedPage = ({
  affiliated_products: initialAffiliatedProducts,
  stats,
  global_affiliates_data: globalAffiliatesData,
  archived_tab_visible: archivedTabVisible,
  pagination: initialPaginationState,
  affiliates_disabled_reason: affiliatesDisabledReason,
}: Props) => {
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
    query: "",
  });
  const { affiliatedProducts, pagination } = state;
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
      if (e instanceof AbortError) return;
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
            <Icon name="x-circle" />
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
      {isShowingGlobalAffiliates ? (
        <GlobalAffiliates
          globalAffiliateId={globalAffiliatesData.global_affiliate_id}
          totalSales={globalAffiliatesData.global_affiliate_sales}
          cookieExpiryDays={globalAffiliatesData.cookie_expiry_days}
          affiliateQueryParam={globalAffiliatesData.affiliate_query_param}
        />
      ) : (
        <section className="p-4 md:p-8">
          {initialAffiliatedProducts.length === 0 ? (
            <div className="placeholder">
              <figure>
                <img src={placeholder} />
              </figure>
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
            </div>
          ) : (
            <div style={{ display: "grid", gap: "var(--spacer-7)" }}>
              <StatsSection {...stats} />
              {state.affiliatedProducts.length === 0 ? (
                <div className="placeholder">
                  <figure>
                    <img src={placeholder} />
                  </figure>
                  <h2>No affiliated products found.</h2>
                </div>
              ) : (
                <AffiliatedProductsTable
                  affiliatedProducts={affiliatedProducts}
                  pagination={pagination}
                  loadAffiliatedProducts={(page: number, sort: Sort<SortKey> | null) => {
                    void loadAffiliatedProducts(page, state.query, sort);
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

export default register({ component: AffiliatedPage, propParser: createCast() });
