// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import AdminPurchase, { type Purchase } from "$app/components/Admin/Purchases/index";

// The admin purchase page renders inside an Inertia app with Rails routes exposed as a
// `Routes` global. Neither exists in the vitest environment, so stub the routes with
// placeholder hrefs — these tests assert amounts render, not navigation.
vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

vi.mock("@inertiajs/react", () => ({
  Link: ({ children, href, ...props }: { children: React.ReactNode; href: string }) => (
    <a href={href} {...props}>
      {children}
    </a>
  ),
}));

// These subtrees make network calls or depend on browser APIs; they're irrelevant to
// the amount rendering under test.
vi.mock("$app/components/Admin/Commentable", () => ({ default: () => null }));
vi.mock("$app/components/Admin/ActionButton", () => ({ default: () => null }));
vi.mock("$app/components/Admin/Purchases/ResendReceiptForm", () => ({ default: () => null }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/components/CopyToClipboard", () => ({
  CopyToClipboard: ({ children }: { children: React.ReactNode }) => children,
}));

const basePurchase: Purchase = {
  external_id: "purchase-external-id",
  seller: { support_email: null, email: "seller@example.com" },
  merchant_account: null,
  fee_cents: 135,
  tip: null,
  formatted_seller_tax_amount: null,
  gumroad_tax_cents: 0,
  formatted_display_price: "$10",
  formatted_gumroad_tax_amount: null,
  formatted_shipping_amount: null,
  formatted_affiliate_credit_amount: null,
  gumroad_responsible_for_tax: false,
  product: { external_id: "product-external-id", name: "Test product", long_url: "https://example.com/l/test" },
  variants_list: "",
  created_at: "2026-07-01T00:00:00Z",
  updated_at: "2026-07-01T00:00:00Z",
  deleted_at: null,
  email: "buyer@example.com",
  purchase_state: "successful",
  formatted_total_transaction_amount: "$10",
  formatted_presentment_total: null,
  formatted_usd_transaction_total: null,
  charge_processor_id: "stripe",
  stripe_transaction: null,
  external_id_numeric: 123456,
  quantity: 1,
  refunds: [],
  card: null,
  ip_address: null,
  ip_country: null,
  is_preorder_authorization: false,
  subscription: null,
  email_info: null,
  is_bundle_purchase: false,
  product_purchases: [],
  url_redirect: null,
  offer_code: null,
  street_address: null,
  full_name: null,
  city: null,
  state: null,
  zip_code: null,
  country: null,
  custom_fields: [],
  license: null,
  affiliate_email: null,
  refund_policy: null,
  can_contact: true,
  gift: null,
  successful: true,
  can_force_update: false,
  failed: false,
  stripe_fingerprint: null,
  stripe_risk_level: null,
  is_free_trial_purchase: false,
  buyer_blocked: false,
  is_deleted_by_buyer: false,
  is_guest_buyer: false,
  is_buyer_email_anonymized: false,
  comments_count: 0,
  stripe_refunded: false,
  stripe_partially_refunded: false,
  chargedback: false,
  chargeback_reversed: false,
  error_code: null,
  last_chargebacked_purchase: null,
};

// Find the <dd> paired with a given <dt> label inside the page's definition lists.
const definitionFor = (container: HTMLElement, label: string): string => {
  const dt = Array.from(container.querySelectorAll("dt")).find((el) => el.textContent === label);
  if (!dt) throw new Error(`No <dt> with label "${label}"`);
  const dd = dt.nextElementSibling;
  if (!(dd instanceof HTMLElement) || dd.tagName !== "DD") throw new Error(`No <dd> after "${label}"`);
  return (dd.textContent ?? "").replace(/\s+/gu, " ").trim();
};

describe("AdminPurchase", () => {
  afterEach(cleanup);

  it("renders the paired USD (presentment) transaction total and per-refund presentment amounts for a buyer-currency purchase", () => {
    const purchase: Purchase = {
      ...basePurchase,
      formatted_total_transaction_amount: "$13.79",
      formatted_usd_transaction_total: "$13.79",
      formatted_presentment_total: "€11.98",
      stripe_partially_refunded: true,
      refunds: [
        {
          user: null,
          status: "succeeded",
          created_at: "2026-07-02T00:00:00Z",
          formatted_usd_amount: "$5",
          formatted_presentment_amount: "€4.34",
        },
      ],
    };

    const { container, getByText } = render(<AdminPurchase purchase={purchase} />);

    expect(definitionFor(container, "Transaction Total")).toEqual("$13.79 (€11.98)");

    const refundAmount = getByText(/Amount:/u);
    // JSX collapses the newline between the "Amount:" literal and the expression, so
    // there is no space after the colon in the rendered text.
    expect((refundAmount.textContent ?? "").replace(/\s+/gu, " ").trim()).toEqual("Amount:$5 (€4.34)");
  });

  it("renders only the display-currency total and no refund amount line for a purchase without presentment data", () => {
    const purchase: Purchase = {
      ...basePurchase,
      formatted_total_transaction_amount: "$10",
      stripe_refunded: true,
      refunds: [
        {
          user: null,
          status: "succeeded",
          created_at: "2026-07-02T00:00:00Z",
          // Refunds created before presentment snapshots existed have neither amount.
          formatted_usd_amount: null,
          formatted_presentment_amount: null,
        },
      ],
    };

    const { container, queryByText } = render(<AdminPurchase purchase={purchase} />);

    expect(definitionFor(container, "Transaction Total")).toEqual("$10");
    // No parenthesized second-currency amount anywhere on the page.
    expect(container.textContent).not.toMatch(/\([^)]*[€£¥$]/u);
    // The refund block renders (status, date) but skips the Amount line entirely.
    expect(queryByText(/Refund Status:/u)).not.toBeNull();
    expect(queryByText(/Amount:/u)).toBeNull();
  });
});
