import React from "react";
import { cast } from "ts-safe-cast";

import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";

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
  const [selectedPurchaseExternalIds, setSelectedPurchaseExternalIds] = React.useState<string[]>([]);
  const [isMassRefunding, setIsMassRefunding] = React.useState(false);

  const togglePurchaseSelection = React.useCallback((purchaseId: string, selected: boolean) => {
    setSelectedPurchaseExternalIds((prev) =>
      selected ? [...prev, purchaseId] : prev.filter((id) => id !== purchaseId),
    );
  }, []);

  const clearSelection = React.useCallback(() => setSelectedPurchaseExternalIds([]), []);

  const selectAll = React.useCallback(
    () => setSelectedPurchaseExternalIds(purchases.filter((p) => p.stripe_refunded !== true).map((p) => p.external_id)),
    [purchases],
  );

  const handleMassRefund = React.useCallback(async () => {
    const selectionCount = selectedPurchaseExternalIds.length;
    if (selectionCount === 0 || isMassRefunding) return;
    const confirmMessage = `Are you sure you want to refund ${selectionCount} ${
      selectionCount === 1 ? "purchase" : "purchases"
    } for fraud and block the buyers?`;
    // eslint-disable-next-line no-alert
    if (!confirm(confirmMessage)) {
      return;
    }

    const csrfToken = cast<string>($("meta[name=csrf-token]").attr("content"));

    setIsMassRefunding(true);

    try {
      const response = await request({
        url: Routes.mass_refund_for_fraud_admin_product_purchases_path(productId, { format: "json" }),
        method: "POST",
        accept: "json",
        data: {
          authenticity_token: csrfToken,
          purchase_ids: selectedPurchaseExternalIds,
        },
      });

      const body = cast<{ success: boolean; message?: string | null }>(await response.json());
      if (!response.ok || !body.success) {
        throw new ResponseError(body.message ?? "Something went wrong.");
      }

      showAlert(body.message ?? "Mass fraud refund started.", "success");
      setSelectedPurchaseExternalIds([]);
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setIsMassRefunding(false);
    }
  }, [isMassRefunding, productId, selectedPurchaseExternalIds]);

  if (purchases.length === 0 && !isLoading)
    return (
      <Alert role="status" variant="info">
        No purchases have been made.
      </Alert>
    );

  const selectedCount = selectedPurchaseExternalIds.length;
  const selectablePurchases = purchases.filter((p) => p.stripe_refunded !== true);
  const allSelectableSelected = selectablePurchases.every((p) => selectedPurchaseExternalIds.includes(p.external_id));

  return (
    <div className="flex flex-col gap-4">
      <div className="mass-refund-toolbar flex flex-wrap items-center justify-between gap-3">
        <div>
          {selectedCount > 0
            ? `${selectedCount} ${selectedCount === 1 ? "purchase selected" : "purchases selected"}`
            : "Select purchases to refund for fraud"}
        </div>
        <div className="flex items-center gap-2">
          {!allSelectableSelected && selectablePurchases.length > 0 ? (
            <Button small outline onClick={selectAll} disabled={isMassRefunding}>
              Select all
            </Button>
          ) : null}
          {selectedCount > 0 ? (
            <Button small outline onClick={clearSelection} disabled={isMassRefunding}>
              Clear selection
            </Button>
          ) : null}
          <Button small onClick={() => void handleMassRefund()} disabled={selectedCount === 0 || isMassRefunding}>
            {isMassRefunding ? "Starting..." : "Refund for Fraud"}
          </Button>
        </div>
      </div>

      <div className="stack">
        {purchases.map((purchase) => (
          <AdminProductPurchase
            key={purchase.external_id}
            purchase={purchase}
            isSelected={selectedPurchaseExternalIds.includes(purchase.external_id)}
            onToggleSelection={togglePurchaseSelection}
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
