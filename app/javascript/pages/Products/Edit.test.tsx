// @vitest-environment happy-dom
import { act, cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

import ProductEditInertiaPage from "$app/pages/Products/Edit";

Object.assign(globalThis, { SSR: false });

// One entry per LazyProductEditPage INSTANCE lifetime. The editor seeds its
// state from props once (useState(props.product)), so navigating between
// products must remount it — the key by product id is what guarantees that.
const mounts = vi.hoisted((): string[] => []);
vi.mock("$app/components/ProductEdit/load", () => ({
  LazyProductEditPage: ({ id }: { id: string }) => {
    React.useEffect(() => {
      mounts.push(id);
    }, []);
    return null;
  },
}));

const pageProps = vi.hoisted((): { current: Record<string, unknown> } => ({ current: {} }));
vi.mock("@inertiajs/react", () => ({
  usePage: () => ({ props: pageProps.current }),
}));

vi.mock("$app/hooks/useDropbox", () => ({ useDropbox: () => {} }));

const makePageProps = (id: string): Record<string, unknown> => ({
  dropbox_api_key: null,
  id,
  unique_permalink: `permalink-${id}`,
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
  successful_sales_count: 0,
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
  ai_generated: false,
  product: {
    name: `Product ${id}`,
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
    confirmed_removed_variant_ids: [],
    confirmed_removed_rich_content_ids: [],
  },
});

beforeEach(() => {
  mounts.length = 0;
});

afterEach(cleanup);

it("remounts the editor when the Inertia visit switches products, and only then", async () => {
  pageProps.current = makePageProps("product-a");
  const { rerender } = render(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(mounts).toEqual(["product-a"]);

  // Same product, refreshed props: the editor instance (and its state) stays.
  pageProps.current = makePageProps("product-a");
  rerender(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(mounts).toEqual(["product-a"]);

  // Different product: the editor must remount so its state reseeds from the
  // new product's props.
  pageProps.current = makePageProps("product-b");
  rerender(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(mounts).toEqual(["product-a", "product-b"]);
});
