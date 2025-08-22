import * as React from "react";
import { register } from "$app/utils/serverComponentUtil";
import { createCast } from "ts-safe-cast";

import { Layout } from "$app/components/CheckoutDashboard/Layout";
import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { showAlert } from "$app/components/server-components/Alert";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import {
  quickCreateCode,
  exportCollectionCsv
} from "$app/data/discount_collection";

type DiscountCollection = {
  id: string;
  name: string;
  description: string | null;
  has_defaults: boolean;
  defaults: {
    discount_type: "percent" | "cents" | null;
    discount_value: number | null;
    max_purchase_count: number | null;
    valid_at: string | null;
    expires_at: string | null;
    minimum_quantity: number | null;
    duration_in_billing_cycles: number | null;
    minimum_amount_cents: number | null;
  };
};

type OfferCode = {
  id: string;
  name: string;
  code: string;
  discount: { type: "cents" | "percent"; value: number };
  max_purchase_count: number | null;
  total_uses: number;
  revenue_cents: number;
  valid_at: string | null;
  expires_at: string | null;
  created_at: string;
  can_update: boolean;
  can_destroy: boolean;
};

type DiscountCollectionDetailPageProps = {
  discount_collection: DiscountCollection;
  offer_codes: OfferCode[];
};

const formatAmount = (offerCode: OfferCode) =>
  offerCode.discount.type === "cents"
    ? formatPriceCentsWithCurrencySymbol("usd", offerCode.discount.value, {
        symbolFormat: "short",
      })
    : `${offerCode.discount.value}%`;

const formatRevenue = (revenue: number) => formatPriceCentsWithCurrencySymbol("usd", revenue, { symbolFormat: "long" });
const formatUses = (uses: number, limit: number | null) => `${uses}/${limit ?? "∞"}`;

const DiscountCollectionDetailPage = ({
  discount_collection,
  offer_codes,
}: DiscountCollectionDetailPageProps) => {
  const [isLoading, setIsLoading] = React.useState(false);
  const [quickCodeName, setQuickCodeName] = React.useState("");

  const handleQuickCreate = asyncVoid(async () => {
    if (!discount_collection.has_defaults) {
      showAlert("Collection must have default discount parameters set", "error");
      return;
    }

    try {
      setIsLoading(true);
      const response = await quickCreateCode(discount_collection.id, quickCodeName || undefined);

      if (response.success) {
        showAlert("Quick code created successfully!", "success");
        setQuickCodeName("");
        // Refresh the page to show the new code
        window.location.reload();
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsLoading(false);
    }
  });

  const handleExportCsv = asyncVoid(async () => {
    try {
      const response = await exportCollectionCsv(discount_collection.id);
      const blob = new Blob([response], { type: 'text/csv' });
      const url = window.URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `${discount_collection.name.replace(/[^a-zA-Z0-9]/g, '-').toLowerCase()}-discount-codes-${new Date().toISOString().split('T')[0]}.csv`;
      document.body.appendChild(a);
      a.click();
      window.URL.revokeObjectURL(url);
      document.body.removeChild(a);
      showAlert("CSV exported successfully!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  return (
    <Layout
      currentPage="discount_collections"
      pages={["discount_collections"]}
      actions={
        <>
          <Button
            color="primary"
            onClick={handleExportCsv}
            disabled={offer_codes.length === 0}
          >
            <Icon name="download" />
            Export CSV
          </Button>
          <Button
            color="accent"
            onClick={handleQuickCreate}
            disabled={!discount_collection.has_defaults || isLoading}
          >
            <Icon name="plus" />
            {isLoading ? "Creating..." : "Quick Create Code"}
          </Button>
        </>
      }
    >
      <section className="paragraphs">
        <div style={{ display: "grid", gap: "var(--spacer-4)" }}>
          <div>
            <h1>{discount_collection.name}</h1>
            {discount_collection.description && (
              <p className="text-muted">{discount_collection.description}</p>
            )}
          </div>

          {discount_collection.has_defaults && (
            <div className="card">
              <h3>Collection Defaults</h3>
              <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                <div>
                  <strong>Discount:</strong> {discount_collection.defaults.discount_value}
                  {discount_collection.defaults.discount_type === 'percent' ? '%' : ' cents'}
                </div>
                {discount_collection.defaults.max_purchase_count && (
                  <div><strong>Max Uses:</strong> {discount_collection.defaults.max_purchase_count}</div>
                )}
                {discount_collection.defaults.valid_at && (
                  <div><strong>Valid From:</strong> {new Date(discount_collection.defaults.valid_at).toLocaleDateString()}</div>
                )}
                {discount_collection.defaults.expires_at && (
                  <div><strong>Expires At:</strong> {new Date(discount_collection.defaults.expires_at).toLocaleDateString()}</div>
                )}
              </div>
            </div>
          )}

          {discount_collection.has_defaults && (
            <div className="card">
              <h3>Quick Create Code</h3>
              <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                <input
                  type="text"
                  placeholder="Code name (optional)"
                  value={quickCodeName}
                  onChange={(e) => setQuickCodeName(e.target.value)}
                  className="input"
                />
                <Button
                  onClick={handleQuickCreate}
                  disabled={isLoading}
                  small
                >
                  {isLoading ? "Creating..." : "Create Code with Defaults"}
                </Button>
              </div>
            </div>
          )}

          <div>
            <h2>Discount Codes ({offer_codes.length})</h2>
            {offer_codes.length > 0 ? (
              <table>
                <thead>
                  <tr>
                    <th>Code</th>
                    <th>Discount</th>
                    <th>Uses</th>
                    <th>Revenue</th>
                    <th>Created</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {offer_codes.map((offerCode) => (
                    <tr key={offerCode.id}>
                      <td>
                        <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                          <div className="pill small">{offerCode.code.toUpperCase()}</div>
                          <b>{offerCode.name}</b>
                        </div>
                      </td>
                      <td>{formatAmount(offerCode)}</td>
                      <td>{formatUses(offerCode.total_uses, offerCode.max_purchase_count)}</td>
                      <td>{formatRevenue(offerCode.revenue_cents)}</td>
                      <td>{new Date(offerCode.created_at).toLocaleDateString()}</td>
                      <td>
                        <div className="actions">
                          <CopyToClipboard
                            text={offerCode.code}
                          >
                            <Button small>
                              <Icon name="outline-duplicate" />
                            </Button>
                          </CopyToClipboard>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : (
              <p className="text-muted">No discount codes in this collection yet.</p>
            )}
          </div>
        </div>
      </section>
    </Layout>
  );
};

export default register({ component: DiscountCollectionDetailPage, propParser: createCast() });
