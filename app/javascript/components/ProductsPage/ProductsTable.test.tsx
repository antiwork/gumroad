// @vitest-environment happy-dom
//
// Covers the widened hit area on the Products table (gumroad-private#1469). Sellers reported that
// clicking a product row "does nothing": only the bold name text was clickable, so a tap on the
// dead space beside it went nowhere. The fix stretches the product link over the whole name cell
// with an absolutely-positioned overlay. These tests pin down two things:
//
//   * a click anywhere in the name cell — specifically on the overlay that fills the space beside
//     and around the name — resolves to the product's edit link, and
//   * the widening did not multiply what assistive tech announces: still exactly one link named
//     after the product per row, and no anchor nested inside another anchor.
//
// happy-dom has no layout engine, so "the overlay fills the cell" is asserted structurally (the
// cell is the positioning context, the overlay is `absolute inset-0` inside the link) rather than
// by pixel geometry; the geometric behaviour is covered by the Capybara system spec in
// spec/requests/products/index_spec.rb, which clicks real coordinates in a real browser.
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { Product } from "$app/data/products";

import { ProductsPageProductsTable } from "$app/components/ProductsPage/ProductsTable";
import { UserAgentProvider } from "$app/components/UserAgent";

// The table renders inside an Inertia app with Rails routes exposed as a `Routes` global. Neither
// exists under vitest, so stub the routes with placeholder hrefs — these tests assert the shape of
// the product link, not the sales-count link.
vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

// Render Inertia's `Link` as the plain anchor it becomes in the DOM; the router only needs to
// exist so the sort/pagination handlers can be created.
vi.mock("@inertiajs/react", () => ({
  Link: ({ children, href, ...props }: { children: React.ReactNode; href: string }) => (
    <a href={href} {...props}>
      {children}
    </a>
  ),
  router: { reload: vi.fn(), get: vi.fn() },
}));

// The actions popover pulls in modal and network machinery that is irrelevant to link layout.
vi.mock("$app/components/ProductsPage/ActionsPopover", () => ({ default: () => null }));

const product: Product = {
  id: 1,
  edit_url: "/products/abc123/edit",
  is_duplicating: false,
  name: "Course in a Box",
  permalink: "abc123",
  price_formatted: "$10",
  revenue: 1000,
  display_price_cents: 1000,
  successful_sales_count: 3,
  remaining_for_sale_count: null,
  status: "published",
  thumbnail: null,
  url: "https://creator.gumroad.com/l/abc123",
  url_without_protocol: "creator.gumroad.com/l/abc123",
  can_edit: true,
  can_duplicate: false,
  can_destroy: false,
  can_archive: false,
  can_unarchive: false,
};

const renderTable = (entries: Product[] = [product]) =>
  render(
    <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
      <ProductsPageProductsTable
        entries={entries}
        pagination={{ page: 1, pages: 1 }}
        selectedTab="products"
        query={null}
        sort={null}
        setEnableArchiveTab={undefined}
      />
    </UserAgentProvider>,
  );

afterEach(cleanup);

describe("ProductsPageProductsTable hit area", () => {
  it("resolves a click anywhere in the name cell — not just on the name text — to the edit link", () => {
    renderTable();

    const editLink = screen.getByRole("link", { name: "Course in a Box" });
    expect(editLink.getAttribute("href")).toBe("/products/abc123/edit");

    // The overlay is the widened hit area: an empty span stretched over the whole cell. It must
    // live inside the edit link so that a click on it IS a click on the link, and the cell must be
    // the positioning context it stretches within.
    const overlay = editLink.querySelector("span[aria-hidden='true']");
    expect(overlay).not.toBeNull();
    expect(overlay?.className).toContain("absolute");
    expect(overlay?.className).toContain("inset-0");
    const cell = editLink.closest("td");
    expect(cell?.className).toContain("relative");

    // A click landing on the overlay (i.e. on the dead space beside the name) bubbles up through
    // the edit link — the browser would navigate to the product editor.
    let clickedHref: string | null | undefined;
    const capture = (event: Event) => {
      event.preventDefault();
      if (event.target instanceof Element) clickedHref = event.target.closest("a")?.getAttribute("href");
    };
    document.addEventListener("click", capture);
    if (overlay instanceof HTMLElement) overlay.click();
    document.removeEventListener("click", capture);

    expect(clickedHref).toBe("/products/abc123/edit");
  });

  it("keeps the storefront URL as its own link, layered above the widened edit link", () => {
    renderTable();

    // The URL under the name still opens the storefront, not the editor — it must be positioned
    // (non-static) so it stacks above the overlay and wins the tap on its own text.
    const storefrontLink = screen.getByRole("link", { name: "creator.gumroad.com/l/abc123" });
    expect(storefrontLink.getAttribute("href")).toBe("https://creator.gumroad.com/l/abc123");
    expect(storefrontLink.className).toContain("relative");
  });

  it("announces exactly one link per row for the product name, with no nested anchors", () => {
    renderTable();

    // Widening the hit area with an aria-hidden overlay must not create a second announced link:
    // screen-reader users should hear the product name once.
    expect(screen.getAllByRole("link", { name: "Course in a Box" })).toHaveLength(1);

    // Nested interactive elements are invalid HTML and produce broken focus order.
    expect(document.querySelectorAll("a a")).toHaveLength(0);
  });
});
