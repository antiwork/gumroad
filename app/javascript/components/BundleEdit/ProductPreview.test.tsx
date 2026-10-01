// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("$app/components/CurrentSeller", () => ({
  useCurrentSeller: () => ({ id: "1", name: "Seller", avatarUrl: "", subdomain: "seller" }),
}));

vi.mock("$app/components/Product/CoffeeProduct", () => ({ CoffeeProduct: () => null }));
vi.mock("$app/components/Profile/Layout", () => ({ Layout: () => null }));
vi.mock("$app/components/BundleEdit/Layout", () => ({ useProductUrl: () => "https://seller.test.gumroad.com/l/b" }));
vi.mock("$app/components/ProductEdit/RefundPolicy", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/components/ProductEdit/RefundPolicy")>()),
  RefundPolicyModalPreview: () => null,
}));

const captured = vi.hoisted<{ product: { refund_policy: unknown } | undefined }>(() => ({ product: undefined }));
vi.mock("$app/components/Product", () => ({
  ProductDiscount: {},
  Product: ({ product }: { product: { refund_policy: unknown } }) => {
    captured.product = product;
    return null;
  },
}));

const { ProductPreview } = await import("$app/components/BundleEdit/ProductPreview");

type ProductPreviewBundle = Parameters<typeof ProductPreview>[0]["bundle"];

beforeAll(() => {
  Object.assign(globalThis, { Routes: { root_url: () => "https://seller.test.gumroad.com" } });
});

afterEach(() => {
  cleanup();
  captured.product = undefined;
});

const baseBundle: ProductPreviewBundle = {
  name: "Test bundle",
  description: "",
  covers: [],
  collaborating_user: null,
  customizable_price: false,
  price_cents: 100,
  suggested_price_cents: null,
  max_purchase_count: null,
  allow_installment_plan: false,
  installment_plan: null,
  display_product_reviews: false,
  quantity_enabled: false,
  should_show_sales_count: false,
  custom_button_text_option: null,
  custom_summary: null,
  custom_attributes: [],
  refund_policy: {
    allowed_refund_periods_in_days: [{ key: 30, value: "30-day money back guarantee" }],
    max_refund_period_in_days: 30,
    fine_print_enabled: false,
    fine_print: null,
    title: "30-day money back guarantee",
  },
  product_refund_policy_enabled: false,
  public_files: [],
  is_published: false,
  products: [],
};

const renderPreview = ({
  bundle,
  sellerRefundPolicyEnabled = false,
  sellerRefundPolicy = { title: "", fine_print: null },
}: {
  bundle: ProductPreviewBundle;
  sellerRefundPolicyEnabled?: boolean;
  sellerRefundPolicy?: { title: string; fine_print: string | null };
}) =>
  render(
    <ProductPreview
      bundle={bundle}
      id="bundle-id"
      uniquePermalink="bundle-permalink"
      currencyType="usd"
      salesCountForInventory={0}
      ratings={{ count: 0, average: 0, percentages: [0, 0, 0, 0, 0] }}
      sellerRefundPolicyEnabled={sellerRefundPolicyEnabled}
      sellerRefundPolicy={sellerRefundPolicy}
    />,
  );

describe("BundleEdit ProductPreview refund policy", () => {
  it("renders no refund policy when neither the account nor the bundle has one enabled", () => {
    renderPreview({ bundle: baseBundle });

    expect(captured.product?.refund_policy).toBeNull();
  });

  it("renders the bundle's own policy when its toggle is on", () => {
    renderPreview({ bundle: { ...baseBundle, product_refund_policy_enabled: true } });

    expect(captured.product?.refund_policy).toEqual({
      title: "30-day money back guarantee",
      fine_print: "",
      updated_at: "",
    });
  });

  it("renders the account-level policy even when the bundle toggle is off", () => {
    renderPreview({
      bundle: baseBundle,
      sellerRefundPolicyEnabled: true,
      sellerRefundPolicy: { title: "Account-wide refunds", fine_print: "Within 30 days." },
    });

    expect(captured.product?.refund_policy).toEqual({
      title: "Account-wide refunds",
      fine_print: "Within 30 days.",
      updated_at: "",
    });
  });
});
