// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { type Page } from "$app/components/ProductEdit/ContentTab/PageTab";
import { EmptyVersionsNotice } from "$app/components/ProductEdit/ProductTab/EmptyVersionsNotice";
import { type Product, type Version } from "$app/components/ProductEdit/state";

const context = vi.hoisted(() => {
  const page: Page = { id: "page", title: null, description: {}, updated_at: "2026-01-01T00:00:00Z" };
  const version = (id: string, name: string, richContent: Page[] = []): Version => ({
    id,
    name,
    description: "",
    max_purchase_count: null,
    integrations: { discord: false, circle: false, google_calendar: false },
    rich_content: richContent,
    price_difference_cents: null,
  });
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
  return { page, version, product };
});

vi.mock("$app/components/ProductEdit/state", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/components/ProductEdit/state")>()),
  useProductEditContext: () => ({ product: context.product }),
}));

afterEach(() => {
  cleanup();
  context.product.variants = [];
  context.product.native_type = "digital";
  context.product.has_same_rich_content_for_all_variants = false;
});

it("names the versions that have no files and no content, and leaves the others out", () => {
  context.product.variants = [
    context.version("1", "SMALL CHOIR", [context.page]),
    context.version("2", "MEDIUM CHOIR"),
    context.version("3", "LARGE CHOIR"),
  ];

  render(<EmptyVersionsNotice />);

  const alert = screen.getByRole("status");
  expect(alert.textContent).toContain("MEDIUM CHOIR");
  expect(alert.textContent).toContain("LARGE CHOIR");
  expect(alert.textContent).not.toContain("SMALL CHOIR");
});

it("does not flag a version that has files attached directly", () => {
  const fileOnly = context.version("1", "SMALL CHOIR");
  fileOnly.has_files = true;
  context.product.variants = [fileOnly];

  render(<EmptyVersionsNotice />);

  expect(screen.queryByRole("status")).toBeNull();
});

it("stays silent when every version shares the product-level content", () => {
  context.product.has_same_rich_content_for_all_variants = true;
  context.product.variants = [context.version("1", "MEDIUM CHOIR")];

  render(<EmptyVersionsNotice />);

  expect(screen.queryByRole("status")).toBeNull();
});

it("stays silent for physical products, whose variants are not downloads", () => {
  context.product.native_type = "physical";
  context.product.variants = [context.version("1", "Medium")];

  render(<EmptyVersionsNotice />);

  expect(screen.queryByRole("status")).toBeNull();
});
