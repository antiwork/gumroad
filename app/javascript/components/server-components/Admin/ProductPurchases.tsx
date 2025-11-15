import * as React from "react";
import { createCast } from "ts-safe-cast";

import { ProductPurchase, fetchProductPurchases } from "$app/data/admin/admin_product_purchases";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { showAlert } from "$app/components/server-components/Alert";

const AdminProductPurchases = ({
  product_id,
  is_affiliate_user,
  user_id,
}: {
  product_id: number;
  is_affiliate_user: boolean;
  user_id: number | null;
}) => {
  const [purchases, setPurchases] = React.useState<ProductPurchase[] | null>(null);
  const [currentPage, setCurrentPage] = React.useState(0);
  const [isLoading, setIsLoading] = React.useState(false);
  const [hasMore, setHasMore] = React.useState(false);
  const [selectedPurchaseIds, setSelectedPurchaseIds] = React.useState<Set<number>>(new Set());
  const [isRefunding, setIsRefunding] = React.useState(false);

  const purchasesPerPage = 20;

  const loadPurchases = async () => {
    setIsLoading(true);
    try {
      const result = await fetchProductPurchases(
        product_id,
        currentPage + 1,
        purchasesPerPage,
        is_affiliate_user,
        user_id,
      );
      setPurchases((prev) => [...(prev ?? []), ...result.purchases]);
      setCurrentPage(result.page || 0);
      setHasMore(result.purchases.length === purchasesPerPage);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  const handleTogglePurchase = (purchaseId: number) => {
    setSelectedPurchaseIds((prev) => {
      const newSet = new Set(prev);
      if (newSet.has(purchaseId)) {
        newSet.delete(purchaseId);
      } else {
        newSet.add(purchaseId);
      }
      return newSet;
    });
  };

  const handleToggleAll = () => {
    if (!purchases) return;
    if (selectedPurchaseIds.size === purchases.length) {
      setSelectedPurchaseIds(new Set());
    } else {
      setSelectedPurchaseIds(new Set(purchases.map((p) => p.id)));
    }
  };

  const handleMassRefund = async () => {
    if (selectedPurchaseIds.size === 0) {
      showAlert("Please select at least one purchase to refund", "error");
      return;
    }

    if (!confirm(`Are you sure you want to refund ${selectedPurchaseIds.size} purchase(s) and block the buyers?`)) {
      return;
    }

    setIsRefunding(true);
    try {
      const response = await fetch(Routes.mass_refund_for_fraud_admin_product_path(product_id), {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content || "",
        },
        body: JSON.stringify({ purchase_ids: Array.from(selectedPurchaseIds) }),
      });

      const result = await response.json();

      if (!response.ok || !result.success) {
        throw new Error(result.message || `Server error ${response.status}`);
      }

      const message = result.message || `Successfully processed ${result.refunded_count + result.blocked_count} purchase(s)`;
      showAlert(message, result.message ? "info" : "success");
      setSelectedPurchaseIds(new Set());
      void loadPurchases();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsRefunding(false);
    }
  };

  return (
    <details>
      <summary
        onClick={() => {
          if (!purchases) void loadPurchases();
        }}
      >
        <h3>{is_affiliate_user ? "Affiliate purchases" : "Purchases"}</h3>
      </summary>
      <div className="paragraphs">
        {purchases && purchases.length > 0 ? (
          <>
            <div style={{ marginBottom: "1rem" }}>
              <button
                className="button small"
                onClick={handleToggleAll}
                disabled={isRefunding}
              >
                {selectedPurchaseIds.size === purchases.length ? "Deselect all" : "Select all"}
              </button>
              {selectedPurchaseIds.size > 0 ? (
                <>
                  <button
                    className="button small"
                    onClick={() => void handleMassRefund()}
                    disabled={isRefunding}
                    style={{ marginLeft: "0.5rem" }}
                  >
                    {isRefunding ? "Refunding..." : `Mass refund (${selectedPurchaseIds.size})`}
                  </button>
                </>
              ) : null}
            </div>
            <div className="stack">
              {purchases.map((purchase) => (
                <div key={purchase.id} style={{ display: "flex", alignItems: "flex-start", gap: "0.5rem" }}>
                  <input
                    type="checkbox"
                    checked={selectedPurchaseIds.has(purchase.id)}
                    onChange={() => handleTogglePurchase(purchase.id)}
                    disabled={isRefunding}
                    style={{ marginTop: "0.25rem" }}
                  />
                  <div style={{ flex: 1 }}>
                    <div>
                      <h5>
                        <a href={Routes.admin_purchase_path(purchase.id)}>{purchase.displayed_price}</a>
                        {purchase.gumroad_responsible_for_tax ? ` + ${purchase.formatted_gumroad_tax_amount} VAT` : null}
                      </h5>
                      <small>
                        <ul className="inline">
                          <li>{purchase.purchase_state}</li>
                          {purchase.error_code ? <li>{purchase.error_code}</li> : null}
                          {purchase.is_preorder_authorization ? <li>(pre-order auth)</li> : null}
                          {purchase.stripe_refunded ? (
                            <li>
                              (refunded
                              {purchase.refunded_by.map((refunder) => (
                                <React.Fragment key={refunder.id}>
                                  {" "}
                                  by <a href={Routes.admin_user_path(refunder.id)}>{refunder.email}</a>
                                </React.Fragment>
                              ))}
                              )
                            </li>
                          ) : null}
                          {purchase.is_chargedback ? <li>(chargeback)</li> : null}
                          {purchase.is_chargeback_reversed ? <li>(chargeback_reversed)</li> : null}
                        </ul>
                      </small>
                    </div>
                    <div className="text-right">
                      <a href={Routes.admin_search_purchases_path({ query: purchase.email })}>{purchase.email}</a>
                      <small>{purchase.created}</small>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </>
        ) : null}
        {isLoading ? <LoadingSpinner className="size-3" /> : null}
        {purchases?.length === 0 ? (
          <div className="info" role="status">
            No purchases have been made.
          </div>
        ) : null}
        {hasMore ? (
          <button className="button small" onClick={() => void loadPurchases()} disabled={isLoading}>
            {isLoading ? "Loading..." : "Load more"}
          </button>
        ) : null}
      </div>
    </details>
  );
};

export default register({ component: AdminProductPurchases, propParser: createCast() });
