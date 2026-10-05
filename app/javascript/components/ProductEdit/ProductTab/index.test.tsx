// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { searchProductOfferCodes } from "$app/data/offer_code";

import { CurrentSellerProvider, type CurrentSeller } from "$app/components/CurrentSeller";
import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { ProductTab } from "$app/components/ProductEdit/ProductTab";
import { ProductEditContext, type OfferCode, type Product } from "$app/components/ProductEdit/state";

vi.mock("react-router-dom", () => ({
  Link: ({ to, children }: { to: string; children?: React.ReactNode }) => <a href={to}>{children}</a>,
  useMatches: () => [{ handle: "product" }],
  useNavigate: () => vi.fn(),
}));

vi.mock("$app/components/Preview", () => ({ Preview: () => null }));
vi.mock("$app/components/ProductEdit/Layout", () => ({
  Layout: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
  useProductUrl: () => "https://seller.test.gumroad.com/l/product-permalink",
}));
vi.mock("$app/components/ProductEdit/ProductPreview", () => ({ ProductPreview: () => null }));
vi.mock("$app/components/ProductEdit/ProductTab/DescriptionEditor", () => ({
  DescriptionEditor: () => null,
  useImageUpload: () => ({ isUploading: false, setImagesUploading: vi.fn() }),
}));
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
vi.mock("$app/data/offer_code", () => ({ searchProductOfferCodes: vi.fn() }));
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

afterEach(() => {
  cleanup();
});

const seller: CurrentSeller = {
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

const renderProductTab = (
  product: Product,
  currentSeller: CurrentSeller = seller,
  updateProduct: (update: Partial<Product> | ((product: Product) => void)) => void = vi.fn(),
) =>
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
            updateProduct,
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
            seller_refund_policy_enabled: false,
            seller_refund_policy: { title: "", fine_print: null },
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
          <ProductTab />
        </ProductEditContext.Provider>
      </CurrentSellerProvider>
    </DomainSettingsProvider>,
  );

describe("ProductTab naming fields", () => {
  it("says where the name, call to action and summary appear", () => {
    renderProductTab(baseProduct);

    expect(
      screen.getByRole("textbox", { name: "Name", description: "Shown as the title at the top of your product page." }),
    ).toBeTruthy();
    expect(
      screen.getByRole("combobox", {
        name: "Call to action",
        description:
          "The text on the buy button of your product page. The button shows other text at times, such as “Choose an option”.",
      }),
    ).toBeTruthy();
    expect(
      screen.getByRole("textbox", {
        name: "Summary",
        description: "Shown below the call to action on your product page.",
      }),
    ).toBeTruthy();
  });
});

const defaultOfferCode: OfferCode = {
  id: "offer-code-id",
  code: "DEFAULT10",
  name: "DEFAULT10",
  discount: {
    type: "percent",
    percents: 10,
    product_ids: ["product-id"],
    expires_at: null,
    minimum_quantity: null,
    duration_in_billing_cycles: null,
    minimum_amount_cents: null,
  },
};

describe("ProductTab automatic discount code control", () => {
  it("renders it for a membership product, whose editor otherwise has no price section", () => {
    renderProductTab({ ...baseProduct, native_type: "membership", variants: [] });

    expect(screen.getByRole("switch", { name: "Automatically apply discount code" })).toBeTruthy();
  });

  it("starts the membership control on when the product already has a default code", () => {
    renderProductTab({
      ...baseProduct,
      native_type: "membership",
      variants: [],
      default_offer_code: defaultOfferCode,
    });

    expect(screen.getByRole("switch", { name: "Automatically apply discount code" })).toHaveProperty("checked", true);
  });

  it("still renders it for a non-membership product", () => {
    renderProductTab(baseProduct);

    expect(screen.getByRole("switch", { name: "Automatically apply discount code" })).toBeTruthy();
  });

  it("saves the selected code as the membership's default offer code", async () => {
    vi.mocked(searchProductOfferCodes).mockResolvedValue([defaultOfferCode]);
    const updateProduct = vi.fn();
    renderProductTab({ ...baseProduct, native_type: "membership", variants: [] }, seller, updateProduct);

    fireEvent.click(screen.getByRole("switch", { name: "Automatically apply discount code" }));
    fireEvent.focus(screen.getByPlaceholderText("Begin typing to select a discount code"));
    fireEvent.click(await screen.findByText("DEFAULT10"));

    await waitFor(() =>
      expect(updateProduct).toHaveBeenCalledWith({
        default_offer_code_id: "offer-code-id",
        default_offer_code: defaultOfferCode,
      }),
    );
  });
});
