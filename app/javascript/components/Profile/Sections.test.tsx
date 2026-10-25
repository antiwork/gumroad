// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { CreatorProfile } from "$app/parsers/profile";

import { Section } from "$app/components/Profile/Sections";

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
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

const productsSection = (total: number) => ({
  id: "section-1",
  header: "More from this creator",
  type: "SellerProfileProductsSection" as const,
  show_filters: false,
  default_product_sort: "page_layout" as const,
  search_results: { products: [], tags_data: [], filetypes_data: [], taxonomy_attributes_data: [], total },
  exclude_ids: ["product-1"],
});

const renderSection = (total: number, productPage: boolean) => {
  const section = productsSection(total);
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
});
