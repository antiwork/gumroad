import * as React from "react";

import { BulkPriceResult, bulkUpdatePrices } from "$app/data/product_dashboard";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Input } from "$app/components/ui/Input";

export const BulkPriceModal = ({
  permalinks,
  onClose,
  onDone,
}: {
  permalinks: string[];
  onClose: () => void;
  onDone: () => void;
}) => {
  const [price, setPrice] = React.useState("");
  const [isSaving, setIsSaving] = React.useState(false);
  const [failures, setFailures] = React.useState<BulkPriceResult[] | null>(null);

  const save = async () => {
    setIsSaving(true);
    try {
      const { updated, results } = await bulkUpdatePrices(permalinks, price);
      const failed = results.filter((result) => !result.updated);
      if (updated > 0) onDone();
      if (failed.length === 0) {
        showAlert(`Updated the price of ${updated} ${updated === 1 ? "product" : "products"}.`, "success");
        onClose();
      } else {
        setFailures(failed);
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsSaving(false);
  };

  return (
    <Modal
      open
      onClose={onClose}
      title={`Edit price of ${permalinks.length} ${permalinks.length === 1 ? "product" : "products"}`}
      footer={
        failures ? (
          <Button onClick={onClose}>Close</Button>
        ) : (
          <>
            <Button onClick={onClose} disabled={isSaving}>
              Cancel
            </Button>
            <Button color="accent" onClick={() => void save()} disabled={isSaving || price.trim() === ""}>
              {isSaving ? "Saving..." : "Update prices"}
            </Button>
          </>
        )
      }
    >
      {failures ? (
        <>
          <h4>
            {failures.length} {failures.length === 1 ? "product was" : "products were"} not updated
          </h4>
          <ul>
            {failures.map((failure) => (
              <li key={failure.id}>
                {failure.name ?? failure.id}: {failure.error}
              </li>
            ))}
          </ul>
        </>
      ) : (
        <>
          <label htmlFor="bulk-price">New price (in each product's currency)</label>
          <Input
            id="bulk-price"
            type="text"
            inputMode="decimal"
            placeholder="9.99"
            value={price}
            onChange={(e) => setPrice(e.target.value)}
          />
        </>
      )}
    </Modal>
  );
};
