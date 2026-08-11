// @vitest-environment happy-dom

import { act, cleanup, render, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

import { type SaveProductResponse } from "$app/data/product_edit";

import { showAlert } from "$app/components/server-components/Alert";

import { ProductEditContext, type Product, type Version } from "$app/components/ProductEdit/state";
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

// Pins gumroad-private#2023: `applyCanonicalIds` used to look up a page's SENT
// snapshot (source_id, move_source_scope/id) with a Map keyed on the page id
// alone. Page ids are unique per scope, not globally — a product-level page
// and a variant page (or two variants') can carry the same id mid-move, and
// the second scope's entry silently clobbered the first in that Map. The next
// reconciliation pass then applied one variant's move/source bookkeeping to
// the OTHER variant's page, corrupting the record the server-side "same
// content page more than once" guard checks against. Scope-qualifying the
// lookup key (this fix) keeps each variant's reconciliation reading its own
// sent snapshot even when two pages happen to share a raw id.
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
  // What must NOT happen is tier B's bookkeeping being overwritten with tier
  // A's sent snapshot (or vice versa): with the bug, a
  // scope-blind Map key made tier B's reconciliation read tier A's ScopedPage
  // (scope "tier-a"), so `sentScope` ("tier-a") mismatched tier B's real
  // `currentScope` ("tier-b") and `movedAfterRequest` went true — falsely
  // reintroducing move_source_scope="tier-a" on a page the server actually
  // committed cleanly in tier B's own scope. Fixed, each variant reads its own
  // snapshot, matches its own scope, and the move bookkeeping is cleared.
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

// Pins gumroad-private#2023 follow-up (Greptile P1): applyCanonicalIds keyed
// sentPagesById by the SENT variant id, but read it back with variant.id
// AFTER the variant-id remap loop had already rewritten it to the canonical
// server id — so a page moved into a variant created by this very save
// missed its sent snapshot and lost move_source_scope/move_source_id/
// source_id, leaving the next save unable to represent the move.
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

  // applyRichContentPageSaveResponse's 5th arg (sentScope) comes from the
  // sentPagesById lookup. With the bug, the lookup missed (keyed by the
  // pre-remap local variant id, read back by the post-remap canonical id),
  // so `sent` was undefined and sentScope fell through to undefined instead
  // of the canonical variant id it was actually sent under — collapsing
  // `hasScopeContext` to false and skipping the branch that correctly
  // updates move provenance for a page moved into a variant this save
  // itself created.
  const call = applyRichContentPageSaveResponseSpy.mock.calls[0];
  expect(call).toBeDefined();
  const sentScope = call?.[4];
  expect(sentScope).toBe("server-new-tier");
  expect(contextCapture.current?.richContentIdMappings["server-new-tier\u0000moved-page"]).toBe(
    "server-page-canonical",
  );
});

const buildTier = (id: string, name: string, richContent: Product["rich_content"]): Version => ({
  id,
  name,
  description: "",
  max_purchase_count: null,
  integrations: { discord: false, circle: false, google_calendar: false },
  rich_content: richContent,
  price_difference_cents: 0,
});

const buildTieredProduct = (variants: Version[]): Product => ({
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
  variants,
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
});

const buildTieredProps = (product: Product): ProductEditPageProps => ({
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
});

// Pins the in-flight cross-scope move path: the scoped sentPagesById lookup
// keys on the page's CURRENT container, so a page the seller moves to another
// tier while the save request runs would miss its sent snapshot. The
// `sentPage ?? page` fallback then compared the page's move fields against
// themselves, wrongly entering the "source committed and deleted" branch and
// erasing the move provenance — the next save never deleted the row this save
// created in the old tier. The raw-id fallback (for ids sent under exactly
// one scope) restores the sent snapshot, so `movedAfterRequest` records the
// created row as the source the next save must remove.
it("keeps move provenance for a page moved to another tier while the save was in flight", async () => {
  const product = buildTieredProduct([
    buildTier("tier-a", "Tier A", [
      {
        id: "in-flight-page",
        newlyAdded: true,
        title: "Moved mid-save",
        description: {},
        updated_at: "2026-01-01T00:00:00Z",
      },
    ]),
    buildTier("tier-b", "Tier B", []),
  ]);
  const props = buildTieredProps(product);

  const requests: { resolve: (response: SaveProductResponse) => void }[] = [];
  saveProductMock.mockImplementation(() => new Promise<SaveProductResponse>((resolve) => requests.push({ resolve })));

  render(<ProductEditPage {...props} />);
  await waitFor(() => expect(contextCapture.current).not.toBeNull());

  let save: Promise<boolean> | undefined;
  act(() => {
    save = contextCapture.current?.save();
  });
  await waitFor(() => expect(saveProductMock).toHaveBeenCalledOnce());

  // The seller moves the page from tier A to tier B while the request runs —
  // the same mutation prepareRichContentPagesForMove produces for a newly
  // added page (move_source_scope only; no source row exists yet).
  act(() =>
    contextCapture.current?.updateProduct((current) => {
      const tierA = current.variants.find((variant) => variant.id === "tier-a");
      const tierB = current.variants.find((variant) => variant.id === "tier-b");
      const page = tierA?.rich_content[0];
      if (!tierA || !tierB || !page) throw new Error("expected both tiers and the in-flight page");
      tierA.rich_content = [];
      tierB.rich_content = [{ ...page, move_source_scope: "tier-a" }];
    }),
  );

  await act(async () => {
    requests[0]?.resolve({
      rich_content_id_mappings: { "in-flight-page": "server-page-a" },
      rich_content_id_mappings_by_scope: { "tier-a": { "in-flight-page": "server-page-a" } },
    } satisfies SaveProductResponse);
    await save;
  });

  // The save committed the page in tier A; the row it created is now the
  // exact source the next save must remove when it commits the move to tier
  // B. Erasing this bookkeeping orphans the tier A row.
  const tierB = contextCapture.current?.product.variants.find((variant) => variant.id === "tier-b");
  expect(tierB?.rich_content[0]).toMatchObject({
    id: "server-page-a",
    move_source_scope: "tier-a",
    move_source_id: "server-page-a",
    source_id: "server-page-a",
  });
});

// Same in-flight move, but the raw id was sent under TWO scopes (the
// duplicated-id state this PR legitimizes). The raw-id fallback must not give
// up just because the id appeared twice: the tier B copy that stayed put
// claims its own sent entry via the scoped lookup, so tier A's entry is the
// only unclaimed one and still identifies the moved page's snapshot — keeping
// its provenance and its own scope's canonical id (the global map holds the
// other scope's row).
it("keeps move provenance for an in-flight move when the raw id was sent in two scopes", async () => {
  const product = buildTieredProduct([
    buildTier("tier-a", "Tier A", [
      {
        id: "dup-page",
        newlyAdded: true,
        title: "A",
        description: {},
        updated_at: "2026-01-01T00:00:00Z",
      },
    ]),
    buildTier("tier-b", "Tier B", [
      {
        id: "dup-page",
        newlyAdded: true,
        title: "B",
        description: {},
        updated_at: "2026-01-01T00:00:00Z",
      },
    ]),
    buildTier("tier-c", "Tier C", []),
  ]);
  const props = buildTieredProps(product);

  const requests: { resolve: (response: SaveProductResponse) => void }[] = [];
  saveProductMock.mockImplementation(() => new Promise<SaveProductResponse>((resolve) => requests.push({ resolve })));

  render(<ProductEditPage {...props} />);
  await waitFor(() => expect(contextCapture.current).not.toBeNull());

  let save: Promise<boolean> | undefined;
  act(() => {
    save = contextCapture.current?.save();
  });
  await waitFor(() => expect(saveProductMock).toHaveBeenCalledOnce());

  act(() =>
    contextCapture.current?.updateProduct((current) => {
      const tierA = current.variants.find((variant) => variant.id === "tier-a");
      const tierC = current.variants.find((variant) => variant.id === "tier-c");
      const page = tierA?.rich_content[0];
      if (!tierA || !tierC || !page) throw new Error("expected the tiers and the in-flight page");
      tierA.rich_content = [];
      tierC.rich_content = [{ ...page, move_source_scope: "tier-a" }];
    }),
  );

  await act(async () => {
    requests[0]?.resolve({
      rich_content_id_mappings: { "dup-page": "server-row-b" },
      rich_content_id_mappings_by_scope: {
        "tier-a": { "dup-page": "server-row-a" },
        "tier-b": { "dup-page": "server-row-b" },
      },
    } satisfies SaveProductResponse);
    await save;
  });

  const tierB = contextCapture.current?.product.variants.find((variant) => variant.id === "tier-b");
  const tierC = contextCapture.current?.product.variants.find((variant) => variant.id === "tier-c");
  // Tier B's page stayed put: it takes its own scope's canonical id and
  // carries no move bookkeeping.
  expect(tierB?.rich_content[0]?.id).toBe("server-row-b");
  expect(tierB?.rich_content[0]).not.toHaveProperty("move_source_scope");
  // The moved page adopts tier A's canonical row (the global map points at
  // tier B's row) and records that row as the source to remove next save.
  expect(tierC?.rich_content[0]).toMatchObject({
    id: "server-row-a",
    move_source_scope: "tier-a",
    move_source_id: "server-row-a",
    source_id: "server-row-a",
  });
});

// Hardest ambiguity: BOTH same-id pages move to new tiers during the save, so
// neither claims its sent entry and the unclaimed set alone cannot tell them
// apart. Each page's move_source_scope marker — written when its move began,
// which is the scope it was sent under — identifies its own snapshot. Losing
// them here would erase both pages' provenance and orphan both source rows.
it("keeps both pages' move provenance when two same-id pages move during the save", async () => {
  const product = buildTieredProduct([
    buildTier("tier-a", "Tier A", [
      {
        id: "dup-page",
        newlyAdded: true,
        title: "A",
        description: {},
        updated_at: "2026-01-01T00:00:00Z",
      },
    ]),
    buildTier("tier-b", "Tier B", [
      {
        id: "dup-page",
        newlyAdded: true,
        title: "B",
        description: {},
        updated_at: "2026-01-01T00:00:00Z",
      },
    ]),
    buildTier("tier-c", "Tier C", []),
    buildTier("tier-d", "Tier D", []),
  ]);
  const props = buildTieredProps(product);

  const requests: { resolve: (response: SaveProductResponse) => void }[] = [];
  saveProductMock.mockImplementation(() => new Promise<SaveProductResponse>((resolve) => requests.push({ resolve })));

  render(<ProductEditPage {...props} />);
  await waitFor(() => expect(contextCapture.current).not.toBeNull());

  let save: Promise<boolean> | undefined;
  act(() => {
    save = contextCapture.current?.save();
  });
  await waitFor(() => expect(saveProductMock).toHaveBeenCalledOnce());

  act(() =>
    contextCapture.current?.updateProduct((current) => {
      const [tierA, tierB, tierC, tierD] = current.variants;
      const pageA = tierA?.rich_content[0];
      const pageB = tierB?.rich_content[0];
      if (!tierA || !tierB || !tierC || !tierD || !pageA || !pageB)
        throw new Error("expected the tiers and both in-flight pages");
      tierA.rich_content = [];
      tierB.rich_content = [];
      tierC.rich_content = [{ ...pageA, move_source_scope: "tier-a" }];
      tierD.rich_content = [{ ...pageB, move_source_scope: "tier-b" }];
    }),
  );

  await act(async () => {
    requests[0]?.resolve({
      rich_content_id_mappings: { "dup-page": "server-row-b" },
      rich_content_id_mappings_by_scope: {
        "tier-a": { "dup-page": "server-row-a" },
        "tier-b": { "dup-page": "server-row-b" },
      },
    } satisfies SaveProductResponse);
    await save;
  });

  const tierC = contextCapture.current?.product.variants.find((variant) => variant.id === "tier-c");
  const tierD = contextCapture.current?.product.variants.find((variant) => variant.id === "tier-d");
  expect(tierC?.rich_content[0]).toMatchObject({
    id: "server-row-a",
    move_source_scope: "tier-a",
    move_source_id: "server-row-a",
    source_id: "server-row-a",
  });
  expect(tierD?.rich_content[0]).toMatchObject({
    id: "server-row-b",
    move_source_scope: "tier-b",
    move_source_id: "server-row-b",
    source_id: "server-row-b",
  });
});

// Chained move: tier A's page lands in tier B while tier B's same-id page
// moves on to tier C, all during one in-flight save. Tier A's page now sits
// on tier B's sent key, so a lookup that trusts the current scoped key binds
// it to tier B's snapshot and leaves tier B's page to consume tier A's —
// swapping both pages' canonical ids and provenance, so the next save can
// delete the wrong source rows. The matcher must treat a marked page's
// scoped key as someone else's entry and resolve both pages through their
// move_source_scope markers instead.
it("resolves a chained in-flight move without swapping the two pages' snapshots", async () => {
  const product = buildTieredProduct([
    buildTier("tier-a", "Tier A", [
      {
        id: "dup-page",
        newlyAdded: true,
        title: "A",
        description: {},
        updated_at: "2026-01-01T00:00:00Z",
      },
    ]),
    buildTier("tier-b", "Tier B", [
      {
        id: "dup-page",
        newlyAdded: true,
        title: "B",
        description: {},
        updated_at: "2026-01-01T00:00:00Z",
      },
    ]),
    buildTier("tier-c", "Tier C", []),
  ]);
  const props = buildTieredProps(product);

  const requests: { resolve: (response: SaveProductResponse) => void }[] = [];
  saveProductMock.mockImplementation(() => new Promise<SaveProductResponse>((resolve) => requests.push({ resolve })));

  render(<ProductEditPage {...props} />);
  await waitFor(() => expect(contextCapture.current).not.toBeNull());

  let save: Promise<boolean> | undefined;
  act(() => {
    save = contextCapture.current?.save();
  });
  await waitFor(() => expect(saveProductMock).toHaveBeenCalledOnce());

  act(() =>
    contextCapture.current?.updateProduct((current) => {
      const [tierA, tierB, tierC] = current.variants;
      const pageA = tierA?.rich_content[0];
      const pageB = tierB?.rich_content[0];
      if (!tierA || !tierB || !tierC || !pageA || !pageB)
        throw new Error("expected the tiers and both in-flight pages");
      tierA.rich_content = [];
      tierB.rich_content = [{ ...pageA, move_source_scope: "tier-a" }];
      tierC.rich_content = [{ ...pageB, move_source_scope: "tier-b" }];
    }),
  );

  await act(async () => {
    requests[0]?.resolve({
      rich_content_id_mappings: { "dup-page": "server-row-b" },
      rich_content_id_mappings_by_scope: {
        "tier-a": { "dup-page": "server-row-a" },
        "tier-b": { "dup-page": "server-row-b" },
      },
    } satisfies SaveProductResponse);
    await save;
  });

  const tierB = contextCapture.current?.product.variants.find((variant) => variant.id === "tier-b");
  const tierC = contextCapture.current?.product.variants.find((variant) => variant.id === "tier-c");
  // Tier A's page (now in tier B) keeps tier A's row and provenance.
  expect(tierB?.rich_content[0]).toMatchObject({
    id: "server-row-a",
    move_source_scope: "tier-a",
    move_source_id: "server-row-a",
    source_id: "server-row-a",
  });
  // Tier B's page (now in tier C) keeps tier B's row and provenance.
  expect(tierC?.rich_content[0]).toMatchObject({
    id: "server-row-b",
    move_source_scope: "tier-b",
    move_source_id: "server-row-b",
    source_id: "server-row-b",
  });
});

// A cancelled move erases move_source_scope, so marker absence does not prove
// a page never moved. Page P was SENT mid-move in tier B (marker tier-a);
// same-id page Q was sent unmarked in tier A. During the request, P moves
// back to tier A (cancelling its marker) while Q moves on to tier C (marker
// tier-a). Every scope/id/marker signal now fits two opposite assignments —
// only the reconciliation_id stamped at send time can tell P and Q apart.
// Binding by current scope would hand P tier A's row and Q tier B's row,
// swapping their provenance and deleting the wrong rows on the next save.
it("matches pages by their send-time stamp when a cancelled move erases the marker", async () => {
  const product = buildTieredProduct([
    buildTier("tier-a", "Tier A", [
      {
        id: "dup-page",
        newlyAdded: true,
        title: "Q",
        description: {},
        updated_at: "2026-01-01T00:00:00Z",
      },
    ]),
    buildTier("tier-b", "Tier B", [
      {
        id: "dup-page",
        newlyAdded: true,
        title: "P",
        description: {},
        updated_at: "2026-01-01T00:00:00Z",
        move_source_scope: "tier-a",
      },
    ]),
    buildTier("tier-c", "Tier C", []),
  ]);
  const props = buildTieredProps(product);

  const requests: { resolve: (response: SaveProductResponse) => void }[] = [];
  saveProductMock.mockImplementation(() => new Promise<SaveProductResponse>((resolve) => requests.push({ resolve })));

  render(<ProductEditPage {...props} />);
  await waitFor(() => expect(contextCapture.current).not.toBeNull());

  let save: Promise<boolean> | undefined;
  act(() => {
    save = contextCapture.current?.save();
  });
  await waitFor(() => expect(saveProductMock).toHaveBeenCalledOnce());

  act(() =>
    contextCapture.current?.updateProduct((current) => {
      const [tierA, tierB, tierC] = current.variants;
      const pageQ = tierA?.rich_content[0];
      const pageP = tierB?.rich_content[0];
      if (!tierA || !tierB || !tierC || !pageQ || !pageP)
        throw new Error("expected the tiers and both in-flight pages");
      // P moves back to its source: prepareRichContentPagesForMove cancels
      // the marker. Q moves on to tier C and records its own move.
      const cancelledP = { ...pageP };
      delete cancelledP.move_source_scope;
      tierA.rich_content = [cancelledP];
      tierB.rich_content = [];
      tierC.rich_content = [{ ...pageQ, move_source_scope: "tier-a" }];
    }),
  );

  await act(async () => {
    requests[0]?.resolve({
      rich_content_id_mappings: { "dup-page": "server-row-p" },
      rich_content_id_mappings_by_scope: {
        "tier-a": { "dup-page": "server-row-q" },
        "tier-b": { "dup-page": "server-row-p" },
      },
    } satisfies SaveProductResponse);
    await save;
  });

  const tierA = contextCapture.current?.product.variants.find((variant) => variant.id === "tier-a");
  const tierC = contextCapture.current?.product.variants.find((variant) => variant.id === "tier-c");
  // P (now back in tier A) owns tier B's committed row and must delete it
  // when the next save lands the page in tier A.
  expect(tierA?.rich_content[0]).toMatchObject({
    title: "P",
    id: "server-row-p",
    move_source_scope: "tier-b",
    move_source_id: "server-row-p",
    source_id: "server-row-p",
  });
  // Q (now in tier C) owns tier A's committed row.
  expect(tierC?.rich_content[0]).toMatchObject({
    title: "Q",
    id: "server-row-q",
    move_source_scope: "tier-a",
    move_source_id: "server-row-q",
    source_id: "server-row-q",
  });
});

// The save-time reconciliation_id stamp lands on pages that the last-saved
// baseline clone predates. That difference is save plumbing — a save that
// touches no page content must not report updated content, or a seller with
// sales gets the customer-notification prompt for pages they never edited.
it("does not report a content update when only the send-time stamp differs", async () => {
  const product = buildTieredProduct([
    buildTier("tier-a", "Tier A", [
      {
        id: "existing-page",
        title: "Unchanged",
        description: {},
        updated_at: "2026-01-01T00:00:00Z",
      },
    ]),
  ]);
  const props = { ...buildTieredProps(product), successful_sales_count: 5 };

  saveProductMock.mockResolvedValue({} satisfies SaveProductResponse);
  vi.mocked(showAlert).mockClear();

  render(<ProductEditPage {...props} />);
  await waitFor(() => expect(contextCapture.current).not.toBeNull());

  await act(async () => {
    await contextCapture.current?.save();
  });

  expect(showAlert).toHaveBeenCalledWith("Changes saved!", "success");
});
