// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { CurrentSellerProvider, type CurrentSeller } from "$app/components/CurrentSeller";
import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { Layout } from "$app/components/ProductEdit/Layout";
import { ProductEditContext, type Product } from "$app/components/ProductEdit/state";

vi.mock("react-router-dom", () => ({
  Link: ({ to, children }: { to: string; children?: React.ReactNode }) => <a href={to}>{children}</a>,
  useMatches: () => [{ handle: "product" }],
  useNavigate: () => vi.fn(),
}));

vi.mock("$app/components/Preview", () => ({ Preview: () => null }));
vi.mock("$app/components/PreviewSidebar", () => ({
  PreviewChrome: () => null,
  PreviewSidebar: ({ children }: { children?: React.ReactNode }) => <aside>{children}</aside>,
  WithPreviewSidebar: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
}));
vi.mock("$app/components/RichTextEditor", () => ({ useImageUploadSettings: () => null }));
vi.mock("$app/components/SubtitleList/Row", () => ({ SubtitleFile: () => null }));
vi.mock("$app/components/WithTooltip", () => ({
  WithTooltip: ({ children }: { children?: React.ReactNode }) => <span>{children}</span>,
}));
vi.mock("$app/data/publish_product", () => ({ setProductPublished: vi.fn() }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

beforeAll(() => {
  const url = (path: string) => () => path;
  Object.assign(globalThis, {
    Routes: {
      custom_domain_coffee_url: url("/coffee"),
      edit_link_path: url("/products/product-permalink/edit"),
      new_email_path: url("/emails/new"),
      settings_payments_path: url("/settings/payments"),
      short_link_url: url("/l/product-permalink"),
    },
  });
});

afterEach(cleanup);

const minor: CurrentSeller = {
  id: "1",
  email: "seller@example.com",
  name: "Seller",
  subdomain: "seller",
  avatarUrl: "",
  isBuyer: false,
  timeZone: { name: "UTC", offset: 0 },
  has_published_products: false,
  can_publish_products: true,
  publishBlockedReason: null,
  noPayoutRailInComplianceCountry: false,
  legalGuardianRequirementMet: false,
  legalGuardianUnsupported: false,
  isNameInvalidForEmailDelivery: false,
  profileBackgroundColor: "#ffffff",
  profileHighlightColor: "#000000",
  profileFont: "ABC Favorit",
};

const product: Product = {
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
    allowed_refund_periods_in_days: [],
    max_refund_period_in_days: 30,
    fine_print_enabled: false,
    fine_print: null,
    title: "",
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

const renderLayout = (currentSeller: CurrentSeller) =>
  render(
    <DomainSettingsProvider
      value={{
        scheme: "https",
        appDomain: "app.test.gumroad.com",
        rootDomain: "test.gumroad.com",
        shortDomain: "test.gumroad.com",
        discoverDomain: "discover.test.gumroad.com",
        thirdPartyAnalyticsDomain: "test.gumroad.com",
        apiDomain: "api.test.gumroad.com",
      }}
    >
      <CurrentSellerProvider value={currentSeller}>
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
            existingFiles: [],
            setExistingFiles: vi.fn(),
            awsKey: "",
            s3Url: "",
            availableCountries: [],
            saving: false,
            save: () => Promise.resolve(true),
            variantIdMappings: {},
            richContentIdMappings: {},
            fileIdMappings: {},
            richContentRemovedFileEmbedIds: {},
            googleClientId: "",
            seller_refund_policy_enabled: false,
            seller_refund_policy: { title: "", fine_print: null },
            cancellationDiscountsEnabled: false,
            receiptEmailFrom: "seller@example.com",
            priceCheckerEnabled: false,
            customHtmlPagesEnabled: false,
            customHtmlStoreHostnames: [],
            customHtmlGlobalNavHosts: [],
            customHtmlGlobalNavPaths: [],
            contentUpdates: null,
            setContentUpdates: vi.fn(),
            filesById: new Map(),
            aiGenerated: false,
          }}
        >
          <Layout>Body</Layout>
        </ProductEditContext.Provider>
      </CurrentSellerProvider>
    </DomainSettingsProvider>,
  );

describe("ProductEdit Layout under-18 banner", () => {
  it("points a minor outside the guardian countries at payouts starting at 18", () => {
    renderLayout({ ...minor, legalGuardianUnsupported: true });

    expect(
      screen.getByText(/cannot verify a seller under 18 in your country, even with a legal guardian/u),
    ).toBeTruthy();
    expect(screen.getByRole("link", { name: "Review your payout setup" }).getAttribute("href")).toBe(
      "/settings/payments",
    );
    expect(screen.queryByRole("link", { name: "Add a guardian" })).toBeNull();
  });

  it("still asks a US minor with no guardian on file to add one", () => {
    renderLayout({ ...minor, legalGuardianUnsupported: false });

    expect(screen.getByText(/a parent or guardian needs to be added to your account/u)).toBeTruthy();
    expect(screen.getByRole("link", { name: "Add a guardian" }).getAttribute("href")).toBe("/settings/payments");
    expect(screen.queryByText(/cannot verify a seller under 18/u)).toBeNull();
  });
});
