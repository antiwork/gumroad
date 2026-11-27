// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { CardProduct } from "$app/parsers/product";
import type { CreatorProfile } from "$app/parsers/profile";

import { Section } from "$app/components/Profile/Sections";

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
// The card body reaches for the logged-in user (lazy image loading), which this test does not
// provide; only the grid's own pagination is under test here.
vi.mock("$app/components/Product/Card", () => ({ Card: () => null }));
vi.stubGlobal("Routes", { products_search_path: () => "/products/search" });

const creator_profile: CreatorProfile = {
  external_id: "9334451938077",
  avatar_url: "",
  name: "Seller",
  twitter_handle: null,
  subdomain: null,
  is_verified: false,
  can_edit: false,
};

const productCard = (index: number): CardProduct => ({
  id: `product-${index}`,
  permalink: `product-${index}`,
  name: `Product ${index}`,
  seller: null,
  ratings: null,
  price_cents: 100,
  currency_code: "usd",
  thumbnail_url: null,
  native_type: "digital",
  url: `/l/product-${index}`,
  is_pay_what_you_want: false,
  quantity_remaining: null,
  is_sales_limited: false,
  duration_in_months: null,
  recurrence: null,
});

// `loaded` is the size of the first page the server rendered; `total` is everything the
// section holds, which is what the Load more control has to make reachable.
const productsSection = (total: number, loaded = 0) => ({
  id: "section-1",
  header: "More from this creator",
  type: "SellerProfileProductsSection" as const,
  show_filters: false,
  default_product_sort: "page_layout" as const,
  search_results: {
    products: Array.from({ length: loaded }, (_, index) => productCard(index)),
    tags_data: [],
    filetypes_data: [],
    taxonomy_attributes_data: [],
    total,
  },
  exclude_ids: ["product-1"],
});

const renderSection = (total: number, productPage: boolean, loaded = 0) => {
  const section = productsSection(total, loaded);
  return render(
    <Section
      section={section}
      sections={[section]}
      creator_profile={creator_profile}
      currency_code="usd"
      hideEmptyProductsSection={productPage}
    />,
  );
};

afterEach(() => cleanup());

describe("Section", () => {
  it("hides an empty products section on the product page", () => {
    const { container } = renderSection(0, true);

    expect(container.querySelector("section")).toBeNull();
  });

  it("keeps the empty state on the profile page, where it is actionable", () => {
    renderSection(0, false);

    expect(screen.getByText("No products found")).toBeTruthy();
  });

  it("keeps a products section that still has products on the product page", () => {
    const { container } = renderSection(1, true);

    expect(container.querySelector("section")).not.toBeNull();
  });

  // Scroll-only pagination renders the first page and nothing else, so a seller looking at
  // their own section reads the remaining products as missing.
  it("offers a Load more control when the section holds more products than its first page", () => {
    renderSection(11, false, 9);

    expect(screen.getByText("Load more")).toBeTruthy();
  });

  it("omits the Load more control when the whole section is already rendered", () => {
    renderSection(9, false, 9);

    expect(screen.queryByText("Load more")).toBeNull();
  });
});
