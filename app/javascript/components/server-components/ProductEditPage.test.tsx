// @vitest-environment happy-dom

import { act, cleanup, render, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

import { type SaveProductResponse } from "$app/data/product_edit";

import { ProductEditContext, type Product } from "$app/components/ProductEdit/state";
import { ProductEditPage, type ProductEditPageProps } from "$app/components/server-components/ProductEditPage";

type ProductEditContextValue = NonNullable<React.ContextType<typeof ProductEditContext>>;

const contextCapture: { current: ProductEditContextValue | null } = { current: null };
const saveProductMock = vi.hoisted(() => vi.fn());
const applyRichContentPageSaveResponseSpy = vi.hoisted(() => vi.fn());

vi.mock("react-router-dom", async (importOriginal) => ({
  ...(await importOriginal<typeof import("react-router-dom")>()),
  createBrowserRouter: () => ({}),
  RouterProvider: () => (
    <ProductEditContext.Consumer>
      {(value) => {
        contextCapture.current = value;
        return null;
      }}
    </ProductEditContext.Consumer>
  ),
}));

vi.mock("$app/data/product_edit", async (importOriginal) => {
  const original = await importOriginal<typeof import("$app/data/product_edit")>();
  return {
    ...original,
    saveProduct: saveProductMock,
    applyRichContentPageSaveResponse: (...args: Parameters<typeof original.applyRichContentPageSaveResponse>) => {
      applyRichContentPageSaveResponseSpy(...args);
      return original.applyRichContentPageSaveResponse(...args);
    },
  };
});

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

beforeEach(() => {
  contextCapture.current = null;
  saveProductMock.mockReset();
});

afterEach(cleanup);

it("saves changed state after the active save reconciles server ids", async () => {
  const product: Product = {
    name: "Initial name",
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
    variants: [
      {
        id: "local-version-id",
        newlyAdded: true,
        name: "Version",
        description: "",
        max_purchase_count: null,
        integrations: { discord: false, circle: false, google_calendar: false },
        rich_content: [],
        price_difference_cents: 0,
      },
    ],
    has_same_rich_content_for_all_variants: false,
    is_multiseat_license: false,
    call_limitation_info: null,
    require_shipping: false,
    cancellation_discount: null,
    default_offer_code: null,
    public_files: [],
    community_chat_enabled: false,
    confirmed_removed_variant_ids: [],
    confirmed_removed_rich_content_ids: [],
  };
  const props: ProductEditPageProps = {
    product,
    id: "product-id",
    unique_permalink: "product-permalink",
    thumbnail: null,
    refund_policies: [],
    currency_type: "usd",
    is_tiered_membership: false,
    is_listed_on_discover: false,
    is_physical: false,
    profile_sections: [],
    taxonomies: [],
    taxonomy_attributes: [],
    earliest_membership_price_change_date: "2026-08-10T00:00:00.000Z",
    custom_domain_verification_status: null,
    sales_count_for_inventory: 0,
    ratings: { count: 0, average: 0, percentages: [0, 0, 0, 0, 0] },
    seller: { id: "seller-id", name: "Seller", avatar_url: "", profile_url: "", is_verified: false },
    existing_files: [],
    aws_key: "",
    s3_url: "",
    available_countries: [],
    google_client_id: "",
    seller_refund_policy_enabled: false,
    seller_refund_policy: { title: "", fine_print: null },
    cancellation_discounts_enabled: false,
    receipt_email_from: "seller@example.com",
    price_checker_enabled: false,
    custom_html_pages_enabled: false,
    custom_html_store_hostnames: [],
    custom_html_global_nav_hosts: [],
    custom_html_global_nav_paths: [],
    successful_sales_count: 0,
    ai_generated: false,
  };
  const requests: { resolve: (response: SaveProductResponse) => void }[] = [];
  saveProductMock.mockImplementation(() => new Promise<SaveProductResponse>((resolve) => requests.push({ resolve })));

  render(<ProductEditPage {...props} />);
  await waitFor(() => expect(contextCapture.current).not.toBeNull());

  let firstSave: Promise<boolean> | undefined;
  act(() => {
    firstSave = contextCapture.current?.save();
  });
  await waitFor(() => expect(saveProductMock).toHaveBeenCalledOnce());

  act(() => contextCapture.current?.updateProduct({ name: "Changed name" }));
  await waitFor(() => expect(contextCapture.current?.product.name).toBe("Changed name"));

  let secondSave: Promise<boolean> | undefined;
  act(() => {
    secondSave = contextCapture.current?.save();
  });
  expect(saveProductMock).toHaveBeenCalledOnce();

  await act(async () => {
    requests[0]?.resolve({ variant_id_mappings: { "local-version-id": "server-version-id" } });
    await firstSave;
  });
  await waitFor(() => expect(saveProductMock).toHaveBeenCalledTimes(2));

  const secondProduct: unknown = saveProductMock.mock.calls[1]?.[2];
  expect(secondProduct).toMatchObject({ name: "Changed name", variants: [{ id: "server-version-id" }] });
  expect(secondProduct).not.toHaveProperty("variants.0.newlyAdded");

  await act(async () => {
    requests[1]?.resolve({});
    await secondSave;
  });
  await expect(secondSave).resolves.toBe(true);
});

// Page ids are unique per scope, not globally: two variants can legitimately
// carry the same raw id in one save, so every sent-snapshot lookup in
// `applyCanonicalIds` must be keyed by scope + page id (gumroad-private#2023).
it("reconciles same-id pages in different variant scopes using each variant's own sent snapshot", async () => {
  const product: Product = {
    name: "Tiered product",
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
    variants: [
      {
        id: "tier-a",
        name: "Tier A",
        description: "",
        max_purchase_count: null,
        integrations: { discord: false, circle: false, google_calendar: false },
        // Same client id as tier-b's page below — plausible after a shared/
        // per-tier toggle round-trip generates both from the same source pass.
        rich_content: [
          {
            id: "shared-client-id",
            title: "A",
            description: {},
            updated_at: "2026-01-01T00:00:00Z",
            move_source_scope: null,
            move_source_id: "server-source-a",
            source_id: "server-source-a",
          },
        ],
        price_difference_cents: 0,
      },
      {
        id: "tier-b",
        name: "Tier B",
        description: "",
        max_purchase_count: null,
        integrations: { discord: false, circle: false, google_calendar: false },
        rich_content: [
          {
            id: "shared-client-id",
            title: "B",
            description: {},
            updated_at: "2026-01-01T00:00:00Z",
            move_source_scope: null,
            move_source_id: "server-source-b",
            source_id: "server-source-b",
          },
        ],
        price_difference_cents: 0,
      },
    ],
    has_same_rich_content_for_all_variants: false,
    is_multiseat_license: false,
    call_limitation_info: null,
    require_shipping: false,
    cancellation_discount: null,
    default_offer_code: null,
    public_files: [],
    community_chat_enabled: false,
    confirmed_removed_variant_ids: [],
    confirmed_removed_rich_content_ids: [],
  };
  const props: ProductEditPageProps = {
    product,
    id: "product-id",
    unique_permalink: "product-permalink",
    thumbnail: null,
    refund_policies: [],
    currency_type: "usd",
    is_tiered_membership: true,
    is_listed_on_discover: false,
    is_physical: false,
    profile_sections: [],
    taxonomies: [],
    taxonomy_attributes: [],
    earliest_membership_price_change_date: "2026-08-10T00:00:00.000Z",
    custom_domain_verification_status: null,
    sales_count_for_inventory: 0,
    ratings: { count: 0, average: 0, percentages: [0, 0, 0, 0, 0] },
    seller: { id: "seller-id", name: "Seller", avatar_url: "", profile_url: "", is_verified: false },
    existing_files: [],
    aws_key: "",
    s3_url: "",
    available_countries: [],
    google_client_id: "",
    seller_refund_policy_enabled: false,
    seller_refund_policy: { title: "", fine_print: null },
    cancellation_discounts_enabled: false,
    receipt_email_from: "seller@example.com",
    price_checker_enabled: false,
    custom_html_pages_enabled: false,
    custom_html_store_hostnames: [],
    custom_html_global_nav_hosts: [],
    custom_html_global_nav_paths: [],
    successful_sales_count: 0,
    ai_generated: false,
  };

  saveProductMock.mockResolvedValue({
    rich_content_id_mappings: { "shared-client-id": "server-page-canonical" },
    rich_content_id_mappings_by_scope: {
      "tier-a": { "shared-client-id": "server-page-a" },
      "tier-b": { "shared-client-id": "server-page-b" },
    },
  } satisfies SaveProductResponse);

  render(<ProductEditPage {...props} />);
  await waitFor(() => expect(contextCapture.current).not.toBeNull());

  await act(async () => {
    await contextCapture.current?.save();
  });

  const savedProduct = contextCapture.current?.product;
  const tierA = savedProduct?.variants.find((v) => v.name === "Tier A");
  const tierB = savedProduct?.variants.find((v) => v.name === "Tier B");
  // Each tier must reconcile against its OWN sent snapshot; a scope-blind
  // lookup would hand tier B tier A's snapshot and falsely reintroduce
  // move_source_scope on a page the server committed cleanly.
  expect(tierA?.rich_content[0]?.id).toBe("server-page-a");
  expect(tierB?.rich_content[0]?.id).toBe("server-page-b");
  expect(contextCapture.current?.richContentIdMappings["tier-a\u0000shared-client-id"]).toBe("server-page-a");
  expect(contextCapture.current?.richContentIdMappings["tier-b\u0000shared-client-id"]).toBe("server-page-b");
  expect(tierA?.rich_content[0]?.title).toBe("A");
  expect(tierB?.rich_content[0]?.title).toBe("B");
  expect(tierB?.rich_content[0]).not.toHaveProperty("move_source_scope");
  expect(tierB?.rich_content[0]).not.toHaveProperty("source_id");
  expect(tierA?.rich_content[0]).not.toHaveProperty("move_source_scope");
  expect(tierA?.rich_content[0]).not.toHaveProperty("source_id");
});

// sentPagesById is keyed by the SENT variant id, but the variant-id remap
// loop rewrites variant.id to the canonical server id before the lookup —
// the read-back must translate ids or a newly-created variant's pages miss
// their snapshot and lose move provenance.
it("keeps a newly-created variant's move provenance after its own id is remapped", async () => {
  const product: Product = {
    name: "Tiered product",
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
    variants: [
      {
        id: "local-new-tier",
        newlyAdded: true,
        name: "New Tier",
        description: "",
        max_purchase_count: null,
        integrations: { discord: false, circle: false, google_calendar: false },
        rich_content: [
          {
            id: "moved-page",
            title: "Moved",
            description: {},
            updated_at: "2026-01-01T00:00:00Z",
            move_source_scope: null,
            move_source_id: "server-shared-source",
            source_id: "server-shared-source",
          },
        ],
        price_difference_cents: 0,
      },
    ],
    has_same_rich_content_for_all_variants: false,
    is_multiseat_license: false,
    call_limitation_info: null,
    require_shipping: false,
    cancellation_discount: null,
    default_offer_code: null,
    public_files: [],
    community_chat_enabled: false,
    confirmed_removed_variant_ids: [],
    confirmed_removed_rich_content_ids: [],
  };
  const props: ProductEditPageProps = {
    product,
    id: "product-id",
    unique_permalink: "product-permalink",
    thumbnail: null,
    refund_policies: [],
    currency_type: "usd",
    is_tiered_membership: true,
    is_listed_on_discover: false,
    is_physical: false,
    profile_sections: [],
    taxonomies: [],
    taxonomy_attributes: [],
    earliest_membership_price_change_date: "2026-08-10T00:00:00.000Z",
    custom_domain_verification_status: null,
    sales_count_for_inventory: 0,
    ratings: { count: 0, average: 0, percentages: [0, 0, 0, 0, 0] },
    seller: { id: "seller-id", name: "Seller", avatar_url: "", profile_url: "", is_verified: false },
    existing_files: [],
    aws_key: "",
    s3_url: "",
    available_countries: [],
    google_client_id: "",
    seller_refund_policy_enabled: false,
    seller_refund_policy: { title: "", fine_print: null },
    cancellation_discounts_enabled: false,
    receipt_email_from: "seller@example.com",
    price_checker_enabled: false,
    custom_html_pages_enabled: false,
    custom_html_store_hostnames: [],
    custom_html_global_nav_hosts: [],
    custom_html_global_nav_paths: [],
    successful_sales_count: 0,
    ai_generated: false,
  };

  saveProductMock.mockResolvedValue({
    variant_id_mappings: { "local-new-tier": "server-new-tier" },
    rich_content_id_mappings: { "moved-page": "server-page-canonical" },
    rich_content_id_mappings_by_scope: {
      "local-new-tier": { "moved-page": "server-page-canonical" },
    },
  } satisfies SaveProductResponse);
  applyRichContentPageSaveResponseSpy.mockClear();

  render(<ProductEditPage {...props} />);
  await waitFor(() => expect(contextCapture.current).not.toBeNull());

  await act(async () => {
    await contextCapture.current?.save();
  });

  // sentScope (5th arg) must resolve to the canonical variant id even though
  // the page was sent under the pre-remap local id; undefined here collapses
  // hasScopeContext and skips the move-provenance update.
  const call = applyRichContentPageSaveResponseSpy.mock.calls[0];
  expect(call).toBeDefined();
  const sentScope = call?.[4];
  expect(sentScope).toBe("server-new-tier");
  expect(contextCapture.current?.richContentIdMappings["server-new-tier\u0000moved-page"]).toBe(
    "server-page-canonical",
  );
});
