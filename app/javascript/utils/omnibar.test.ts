import { describe, expect, it } from "vitest";

import { buildOmnibarGroups, matchesQuery, moveActiveId, nextActiveId, type OmnibarItem } from "$app/utils/omnibar";

const pages = [
  { key: "products", title: "Products", href: "/products" },
  { key: "sales", title: "Sales", href: "/customers", keywords: "customers buyers refunds" },
  { key: "payouts", title: "Payouts", href: "/payouts", keywords: "balance bank" },
];
const actions = [{ key: "new-product", title: "New product", href: "/products/new", keywords: "create add" }];
const searchLinks = {
  sales: (query: string) => `/customers?query=${encodeURIComponent(query)}`,
  products: (query: string) => `/products?query=${encodeURIComponent(query)}`,
};
const build = (query: string, results: Parameters<typeof buildOmnibarGroups>[0]["results"] = null) =>
  buildOmnibarGroups({ query, pages, actions, results, searchLinks });
const titles = (groups: ReturnType<typeof build>) => groups.map((group) => group.title);

describe("matchesQuery", () => {
  it("matches every word of the query in any order and any case", () => {
    expect(matchesQuery("NEW prod", "New product")).toBe(true);
    expect(matchesQuery("product new", "New product")).toBe(true);
    expect(matchesQuery("new email", "New product")).toBe(false);
  });

  it("matches on keywords as well as the title", () => {
    expect(matchesQuery("refund", "Sales", "customers buyers refunds")).toBe(true);
  });

  it("matches full-width characters typed on a CJK keyboard", () => {
    expect(matchesQuery("ｐａｙ", "Payouts")).toBe(true);
  });

  it("matches everything for an empty query", () => {
    expect(matchesQuery("  ", "Payouts")).toBe(true);
  });
});

describe("buildOmnibarGroups", () => {
  it("offers every place and action before anything is typed, and no search rows", () => {
    const groups = build("");

    expect(titles(groups)).toEqual(["Go to", "Quick actions"]);
    expect(groups[0]?.items.map((item) => item.title)).toEqual(["Products", "Sales", "Payouts"]);
  });

  it("narrows places and actions as the seller types", () => {
    expect(build("p").flatMap((group) => group.items.map((item) => item.title))).toEqual([
      "Products",
      "Payouts",
      "New product",
    ]);
  });

  // The server answers nothing for one character, so offering to search for it would lead nowhere.
  it("adds the search rows from two characters", () => {
    expect(titles(build("z"))).toEqual([]);
    expect(build("zz")).toEqual([
      {
        title: "Search",
        items: [
          { id: "search:sales", kind: "search", title: "Search sales for “zz”", href: "/customers?query=zz" },
          { id: "search:products", kind: "search", title: "Search products for “zz”", href: "/products?query=zz" },
        ],
      },
    ]);
  });

  it("encodes the query in the search rows' links", () => {
    const search = build("ada+test@example.com").at(-1);

    expect(search?.items[0]?.href).toBe("/customers?query=ada%2Btest%40example.com");
  });

  it("puts results under the places and actions that were already showing", () => {
    const groups = build("pro", {
      products: [{ id: "p1", name: "Pro widget", url: "/products/p1/edit" }],
      customers: [
        {
          id: "c1",
          email: "ada@example.com",
          name: "Ada Prosser",
          product_name: "Pro widget",
          url: "/customers/sale/c1",
        },
        { id: "c2", email: "prolific@example.com", name: "", product_name: "Pro widget", url: "/customers/sale/c2" },
      ],
      customers_unavailable: false,
    });

    expect(titles(groups)).toEqual(["Go to", "Quick actions", "Products", "Sales", "Search"]);
    expect(groups[2]?.items).toEqual([
      { id: "product:p1", kind: "product", title: "Pro widget", href: "/products/p1/edit" },
    ]);
    expect(groups[3]?.items).toEqual([
      {
        id: "customer:c1",
        kind: "customer",
        title: "Ada Prosser",
        detail: "ada@example.com · Pro widget",
        href: "/customers/sale/c1",
      },
      // A buyer with no name is listed by email, which then is not repeated underneath.
      {
        id: "customer:c2",
        kind: "customer",
        title: "prolific@example.com",
        detail: "Pro widget",
        href: "/customers/sale/c2",
      },
    ]);
  });
});

describe("the active row", () => {
  const items: OmnibarItem[] = ["a", "b", "c"].map((id) => ({ id, kind: "page", title: id, href: `/${id}` }));

  it("stays on the same row when rows are added around it", () => {
    expect(nextActiveId(items, "b")).toBe("b");
  });

  it("falls back to the first row when the active one is gone", () => {
    expect(nextActiveId(items, "gone")).toBe("a");
    expect(nextActiveId([], "a")).toBeNull();
  });

  it("moves down and up, wrapping at both ends", () => {
    expect(moveActiveId(items, "a", 1)).toBe("b");
    expect(moveActiveId(items, "c", 1)).toBe("a");
    expect(moveActiveId(items, "a", -1)).toBe("c");
    expect(moveActiveId(items, null, -1)).toBe("c");
    expect(moveActiveId([], null, 1)).toBeNull();
  });
});
