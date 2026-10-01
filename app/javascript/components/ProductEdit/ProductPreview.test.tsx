// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { ProductEditContext, type Product } from "$app/components/ProductEdit/state";

vi.mock("$app/components/CurrentSeller", () => ({
  useCurrentSeller: () => ({ id: "1", name: "Seller", avatarUrl: "", subdomain: "seller" }),
}));
vi.mock("$app/components/Product/CoffeeProduct", () => ({ CoffeeProduct: () => null }));
vi.mock("$app/components/ProductEdit/LandingPagePreview", () => ({ LandingPagePreview: () => null }));
vi.mock("$app/components/ProductEdit/Layout", () => ({ useProductUrl: () => "https://seller.test.gumroad.com/l/p" }));
vi.mock("$app/components/Profile/Layout", () => ({ Layout: () => null }));
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

const { ProductPreview } = await import("$app/components/ProductEdit/ProductPreview");

beforeAll(() => {
  Object.assign(globalThis, { Routes: { root_url: () => "https://seller.test.gumroad.com" } });
});

afterEach(() => {
  cleanup();
  captured.product = undefined;
});

const baseProduct: Product = {
  name: "Test product",
  description: "",
  custom_permalink: null,
  price_cents: 100,
  suggested_price_cents: null,
  customizable_price: false,
  eligible_for_installment_plans: false,
  allow_installment_plan: false,
  installment_plan: null,
  custom_button_text_option: null,
  custom_summary: null,
  custom_html: null,
  custom_view_content_button_text: null,
  custom_view_content_button_text_max_length: 20,
  custom_receipt_text: null,
  custom_receipt_text_max_length: 1_000,
  custom_attributes: [],
  taxonomy_attribute_values: {},
  inferred_taxonomy_attribute_values: {},
  file_attributes: [],
  max_purchase_count: null,
  quantity_enabled: false,
  can_enable_quantity: true,
  should_show_sales_count: false,
  hide_sold_out_variants: false,
  is_epublication: false,
  product_refund_policy_enabled: false,
  refund_policy: {
    allowed_refund_periods_in_days: [{ key: 30, value: "30-day money back guarantee" }],
    max_refund_period_in_days: 30,
    fine_print_enabled: false,
    fine_print: null,
    title: "30-day money back guarantee",
  },
  is_published: false,
  free_trial_enabled: false,
  free_trial_duration_amount: null,
  free_trial_duration_unit: null,
  should_include_last_post: false,
  should_show_all_posts: false,
  block_access_after_membership_cancellation: false,
  duration_in_months: null,
  subscription_duration: null,
  integrations: { discord: null, circle: null, google_calendar: null },
  covers: [],
  availabilities: [],
  section_ids: [],
  taxonomy_id: null,
  tags: [],
  display_product_reviews: false,
  is_adult: false,
  discover_fee_per_thousand: 0,
  shipping_destinations: [],
  custom_domain: "",
  collaborating_user: null,
  native_type: "digital",
  files: [],
  rich_content: [],
  variants: [],
  has_same_rich_content_for_all_variants: false,
  is_multiseat_license: false,
  call_limitation_info: null,
  require_shipping: false,
  cancellation_discount: null,
  default_offer_code: null,
  public_files: [],
  community_chat_enabled: false,
};

const renderPreview = ({
  product,
  sellerRefundPolicyEnabled = false,
  sellerRefundPolicy = { title: "", fine_print: null },
}: {
  product: Product;
  sellerRefundPolicyEnabled?: boolean;
  sellerRefundPolicy?: { title: string; fine_print: string | null };
}) =>
  render(
    <ProductEditContext.Provider
      value={{
        id: "product-id",
        product,
        uniquePermalink: "product-permalink",
        updateProduct: vi.fn(),
        thumbnail: null,
        refundPolicies: [],
        currencyType: "usd",
        setCurrencyType: vi.fn(),
        isListedOnDiscover: false,
        canCloseMembershipTiers: false,
        isPhysical: false,
        profileSections: [],
        taxonomies: [],
        taxonomyAttributes: [],
        earliestMembershipPriceChangeDate: new Date("2026-08-10T00:00:00.000Z"),
        customDomainVerificationStatus: null,
        salesCountForInventory: 0,
        successfulSalesCount: 0,
        ratings: { count: 0, average: 0, percentages: [0, 0, 0, 0, 0] },
        seller: { id: "seller-id", name: "Seller", avatar_url: "", profile_url: "", is_verified: false },
        currentSellerExternalId: "seller-external-id",
        existingFiles: [],
        setExistingFiles: vi.fn(),
        awsKey: "",
        s3Url: "",
        availableCountries: [],
        saving: false,
        saveBlocked: false,
        save: () => Promise.resolve(true),
        variantIdMappings: {},
        richContentIdMappings: {},
        fileIdMappings: {},
        richContentRemovedFileEmbedIds: {},
        googleClientId: "",
        seller_refund_policy_enabled: sellerRefundPolicyEnabled,
        seller_refund_policy: sellerRefundPolicy,
        cancellationDiscountsEnabled: false,
        receiptEmailFrom: "seller@example.com",
        priceCheckerEnabled: false,
        customHtmlPagesEnabled: false,
        autoMarketingEnabled: false,
        customHtmlStoreHostnames: [],
        customHtmlGlobalNavHosts: [],
        customHtmlGlobalNavPaths: [],
        contentUpdates: null,
        setContentUpdates: vi.fn(),
        filesById: new Map(),
        aiGenerated: false,
      }}
    >
      <ProductPreview />
    </ProductEditContext.Provider>,
  );

describe("ProductPreview refund policy", () => {
  it("renders no refund policy when neither the account nor the product has one enabled", () => {
    renderPreview({ product: baseProduct });

    expect(captured.product?.refund_policy).toBeNull();
  });

  it("renders the product's own policy when its toggle is on", () => {
    renderPreview({ product: { ...baseProduct, product_refund_policy_enabled: true } });

    expect(captured.product?.refund_policy).toEqual({
      title: "30-day money back guarantee",
      fine_print: "",
      updated_at: "",
    });
  });

  it("renders the account-level policy even when the product toggle is off", () => {
    renderPreview({
      product: baseProduct,
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
