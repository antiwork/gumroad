import React from "react";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";

import AdminProductPurchase, { ProductPurchase } from "./Purchase";

type AdminProductPurchasesContentProps = {
  purchases: ProductPurchase[];
  isLoading: boolean;
  hasMore: boolean;
  onLoadMore: () => void;
  productId: number;
};

const AdminProductPurchasesContent = ({
  purchases,
  isLoading,
  hasMore,
  onLoadMore,
  productId,
}: AdminProductPurchasesContentProps) => {
  const [selectedPurchaseIds, setSelectedPurchaseIds] = React.useState<Set<number>>(new Set());
  const [isRefunding, setIsRefunding] = React.useState(false);

  if (purchases.length === 0 && !isLoading)
    return (
      <div className="info" role="status">
        No purchases have been made.
      </div>
    );

  const handleSelectionChange = (purchaseId: number, selected: boolean) => {
    setSelectedPurchaseIds((prev) => {
      const next = new Set(prev);
      if (selected) {
        next.add(purchaseId);
      } else {
        next.delete(purchaseId);
      }
      return next;
    });
  };

  const handleSelectAll = (checked: boolean) => {
    if (checked) {
      setSelectedPurchaseIds(new Set(purchases.map((p) => p.id)));
    } else {
      setSelectedPurchaseIds(new Set());
    }
  };

  const handleMassRefund = async () => {
    if (selectedPurchaseIds.size === 0) return;

    const confirmed = window.confirm(
      `Are you sure you want to refund ${selectedPurchaseIds.size} purchase${
        selectedPurchaseIds.size !== 1 ? "s" : ""
      } for fraud?\n\nThis will:\n- Refund successful purchases\n- Block buyers from all selected purchases\n\nThis action cannot be undone.`
    );

    if (!confirmed) return;

    setIsRefunding(true);

    try {
      const response = await fetch(
        Routes.mass_refund_for_fraud_admin_product_purchases_path(productId),
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')
              ?.content || "",
          },
          body: JSON.stringify({
            purchase_ids: Array.from(selectedPurchaseIds),
          }),
        }
      );

      const data = await response.json();

      if (data.success) {
        alert(data.message || "Mass refund completed successfully");
        setSelectedPurchaseIds(new Set());
        // Reload the page to show updated purchase states
        window.location.reload();
      } else {
        alert(data.message || "Failed to process mass refund");
      }
    } catch (error) {
      console.error("Mass refund error:", error);
      alert("An error occurred while processing the refund");
    } finally {
      setIsRefunding(false);
    }
  };

  const allSelected = purchases.length > 0 && purchases.every((p) => selectedPurchaseIds.has(p.id));
  const someSelected = selectedPurchaseIds.size > 0 && !allSelected;

  return (
    <div className="paragraphs">
      {purchases.length > 0 ? (
        <div className="button-group">
          <label style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
            <input
              type="checkbox"
              checked={allSelected}
              ref={(el) => el && (el.indeterminate = someSelected)}
              onChange={(e) => handleSelectAll(e.target.checked)}
              aria-label="Select all purchases"
            />
            <span>
              {allSelected
                ? "Deselect all"
                : someSelected
                  ? `${selectedPurchaseIds.size} selected`
                  : "Select all"}
            </span>
          </label>

          {selectedPurchaseIds.size > 0 ? (
            <Button
              onClick={handleMassRefund}
              disabled={isRefunding}
              color="danger"
            >
              {isRefunding
                ? "Processing..."
                : `Mass Refund for Fraud (${selectedPurchaseIds.size})`}
            </Button>
          ) : null}
        </div>
      ) : null}

      <div className="stack">
        {purchases.map((purchase) => (
          <AdminProductPurchase
            key={purchase.id}
            purchase={purchase}
            isSelected={selectedPurchaseIds.has(purchase.id)}
            onSelectionChange={handleSelectionChange}
            showCheckbox={true}
          />
        ))}
      </div>

      {isLoading ? <LoadingSpinner /> : null}

      {hasMore ? (
        <Button small onClick={onLoadMore} disabled={isLoading}>
          {isLoading ? "Loading..." : "Load more"}
        </Button>
      ) : null}
    </div>
  );
};

export default AdminProductPurchasesContent;
