import * as React from "react";
import { createCast } from "ts-safe-cast";

import { getPagedAffiliatedProducts, approveAffiliateInvitation, denyAffiliateInvitation, revokeAffiliateAccess } from "$app/data/affiliated_products";
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
  affiliate_id?: string; // Only for direct affiliates that can be revoked
};

export type PendingInvitation = {
  id: string;
  product_name: string;
  seller_name: string;
  fee_percentage: number; // In basis points (e.g., 300 = 3%)
  created_at: string;
  product_id: string;
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
  pending_invitations: PendingInvitation[];
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
  onRevoke?: (affiliateId: string) => void;
};

export type SortKey = "product_name" | "sales_count" | "commission" | "revenue";

const AffiliatedProductsTable = ({
  affiliatedProducts,
  pagination,
  loadAffiliatedProducts,
  isLoading,
  onRevoke,
}: AffiliatedProductsTableProps) => {
  const [sort, setSort] = React.useState<Sort<SortKey> | null>(null);
  const thProps = useSortingTableDriver<SortKey>(sort, setSort);
  const userAgentInfo = useUserAgentInfo();

  React.useEffect(() => {
    if (sort) loadAffiliatedProducts(1, sort);
  }, [sort]);

  return (
    <>
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
                  {affiliatedProduct.affiliate_id && onRevoke && (
                    <WithTooltip tip="Remove yourself as an affiliate" position="bottom">
                      <Button
                        color="danger"
                        onClick={() => onRevoke(affiliatedProduct.affiliate_id!)}
                      >
                        <Icon name="trash" />
                        Remove
                      </Button>
                    </WithTooltip>
                  )}
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {pagination.pages > 1 ? (
        <Pagination onChangePage={(page) => loadAffiliatedProducts(page, sort)} pagination={pagination} />
      ) : null}
    </>
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

type PendingInvitationsTableProps = {
  pendingInvitations: PendingInvitation[];
  onApprove: (invitation: PendingInvitation) => void;
  onDeny: (invitation: PendingInvitation) => void;
};

const PendingInvitationsTable = ({ pendingInvitations, onApprove, onDeny }: PendingInvitationsTableProps) => {
  if (pendingInvitations.length === 0) return null;

  // Group invitations by affiliate (seller) to show the relationship correctly
  const groupedInvitations = pendingInvitations.reduce((acc, invitation) => {
    const key = `${invitation.id}-${invitation.seller_name}`;
    if (!acc[key]) {
      acc[key] = {
        id: invitation.id,
        seller_name: invitation.seller_name,
        fee_percentage: invitation.fee_percentage,
        created_at: invitation.created_at,
        products: []
      };
    }
    acc[key].products.push(invitation.product_name);
    return acc;
  }, {} as Record<string, {
    id: string;
    seller_name: string;
    fee_percentage: number;
    created_at: string;
    products: string[];
  }>);

  return (
    <section>
      <h3>Pending Affiliate Invitations</h3>
      <p>You have been invited to become an affiliate by the following creators. <strong>Approving will give you access to promote ALL their products.</strong></p>
      <table>
        <thead>
          <tr>
            <th>Creator</th>
            <th>Products</th>
            <th>Commission</th>
            <th>Invited</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {Object.values(groupedInvitations).map((invitation) => (
            <tr key={invitation.id}>
              <td>{invitation.seller_name}</td>
              <td>
                {invitation.products.length === 1
                  ? invitation.products[0]
                  : `${invitation.products.length} products: ${invitation.products.join(', ')}`
                }
              </td>
              <td>{(invitation.fee_percentage / 10000).toLocaleString([], { style: "percent", minimumFractionDigits: 0 })}</td>
              <td>{new Date(invitation.created_at).toLocaleDateString()}</td>
              <td>
                <div className="actions">
                  <Button color="primary" onClick={() => onApprove(pendingInvitations.find(inv => inv.id === invitation.id)!)}>
                    <Icon name="check" />
                    Approve All
                  </Button>
                  <Button onClick={() => onDeny(pendingInvitations.find(inv => inv.id === invitation.id)!)}>
                    <Icon name="x" />
                    Deny All
                  </Button>
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
};

const AffiliatedPage = ({
  affiliated_products: initialAffiliatedProducts,
  pending_invitations: pendingInvitations,
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
  const [currentPendingInvitations, setCurrentPendingInvitations] = React.useState<PendingInvitation[]>(pendingInvitations);
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

  const handleApproveInvitation = asyncVoid(async (invitation: PendingInvitation) => {
    try {
      const response = await approveAffiliateInvitation(invitation.id);
      if (response.success) {
        setCurrentPendingInvitations(prev => prev.filter(inv => inv.id !== invitation.id));
        showAlert(response.message || "Affiliate invitation approved!", "success");
        // Reload the page to refresh the affiliated products list
        window.location.reload();
      } else {
        showAlert(response.error || "Failed to approve invitation", "error");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  const handleDenyInvitation = asyncVoid(async (invitation: PendingInvitation) => {
    try {
      const response = await denyAffiliateInvitation(invitation.id);
      if (response.success) {
        setCurrentPendingInvitations(prev => prev.filter(inv => inv.id !== invitation.id));
        showAlert(response.message || "Affiliate invitation denied", "success");
      } else {
        showAlert(response.error || "Failed to deny invitation", "error");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  const handleRevokeAffiliate = asyncVoid(async (affiliateId: string) => {
    try {
      const response = await revokeAffiliateAccess(affiliateId);
      if (response.success) {
        showAlert(response.message || "Affiliate access revoked", "success");
        // Reload the page to refresh the affiliated products list
        window.location.reload();
      } else {
        showAlert(response.error || "Failed to revoke affiliate access", "error");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  return (
    <ProductsLayout
      selectedTab="affiliated"
      title={isShowingGlobalAffiliates ? "Gumroad Affiliates" : undefined}
      ctaButton={
        <>
          <Search onSearch={handleSearch} value={state.query} />
          {isShowingGlobalAffiliates ? (
            <Button onClick={() => toggleOpen(false)}>
              <Icon name="x-circle" />
              Close
            </Button>
          ) : (
            <WithTooltip position="bottom" tip={affiliatesDisabledReason}>
              <Button color="accent" disabled={affiliatesDisabledReason !== null} onClick={() => toggleOpen(true)}>
                Gumroad affiliate
              </Button>
            </WithTooltip>
          )}
        </>
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
        <section>
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
                or <a data-helper-prompt="How do I get started as an affiliate?">learn more to get started</a>
              </p>
            </div>
          ) : (
            <div style={{ display: "grid", gap: "var(--spacer-7)" }}>
              <StatsSection {...stats} />
              <PendingInvitationsTable
                pendingInvitations={currentPendingInvitations}
                onApprove={handleApproveInvitation}
                onDeny={handleDenyInvitation}
              />
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
                  onRevoke={handleRevokeAffiliate}
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
