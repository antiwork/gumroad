import { describe, expect, it } from "vitest";

import {
  buildOmnibarGroups,
  isSearchable,
  matchesQuery,
  moveActiveId,
  nextActiveId,
  type OmnibarItem,
  type OmnibarResults,
} from "$app/utils/omnibar";

const pages = [
  { key: "products", title: "Products", href: "/products" },
  { key: "sales", title: "Sales", href: "/customers", keywords: "customers refunds" },
  { key: "payouts", title: "Payouts", href: "/payouts", keywords: "balance bank" },
];
const actions = [{ key: "new-product", title: "New product", href: "/products/new", keywords: "create add" }];
const searchLinks = {
  sales: (query: string) => `/customers?query=${encodeURIComponent(query)}`,
  products: (query: string) => `/products?query=${encodeURIComponent(query)}`,
};
const widget = { id: "p1", name: "Pro widget", url: "/products/p1/edit" };
const ada = {
  id: "s1",
  email: "ada@example.com",
  name: "Ada Prosser",
  product_name: "Pro widget",
  url: "/customers/sale/s1",
};
const build = (query: string, results: OmnibarResults = {}) =>
  buildOmnibarGroups({ query, pages, actions, results, searchLinks });
const titles = (groups: ReturnType<typeof build>) => groups.map((group) => group.title);

describe("matchesQuery", () => {
  it("matches every word of the query in any order and any case", () => {
    expect(matchesQuery("NEW prod", "New product")).toBe(true);
    expect(matchesQuery("product new", "New product")).toBe(true);
    expect(matchesQuery("new email", "New product")).toBe(false);
  });

  it("matches on keywords as well as the title", () => {
    expect(matchesQuery("refund", "Sales", "customers refunds")).toBe(true);
  });

  it("matches full-width characters typed on a CJK keyboard", () => {
    expect(matchesQuery("ｐａｙ", "Payouts")).toBe(true);
  });

  it("matches everything for an empty query", () => {
    expect(matchesQuery("  ", "Payouts")).toBe(true);
  });
});

describe("isSearchable", () => {
  it("starts at two characters, not counting the spaces around them", () => {
    expect(isSearchable(" w ")).toBe(false);
    expect(isSearchable("wi")).toBe(true);
  });

  // The server counts characters. One emoji is two UTF-16 units, and the server would answer nothing.
  it("counts an emoji as one character", () => {
    expect(isSearchable("🎨")).toBe(false);
    expect(isSearchable("🎨🎨")).toBe(true);
  });
});

describe("buildOmnibarGroups", () => {
  it("offers every place and action before anything is typed", () => {
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

  it("carries a place's own handler to its row", () => {
    const onSelect = () => undefined;
    const groups = buildOmnibarGroups({
      query: "",
      pages: [{ key: "community", title: "Community", href: "/communities", onSelect }],
      actions: [],
      results: {},
      searchLinks,
    });

    expect(groups[0]?.items[0]?.onSelect).toBe(onSelect);
  });

  describe("as results arrive", () => {
    const settled = { products: [widget], sales: [ada] };

    it("shows nothing from the server while both requests are out", () => {
      expect(titles(build("pro"))).toEqual(["Go to", "Quick actions"]);
      expect(titles(build("zz"))).toEqual([]);
    });

    it("adds products as soon as they arrive", () => {
      expect(titles(build("pro", { products: [widget] }))).toEqual(["Go to", "Quick actions", "Products"]);
    });

    // Sales shown first would be pushed down when products land above them.
    it("holds sales back until products have arrived", () => {
      expect(titles(build("pro", { sales: [ada] }))).toEqual(["Go to", "Quick actions"]);
    });

    it("adds the search rows last, once both have arrived", () => {
      const groups = build("pro", settled);

      expect(titles(groups)).toEqual(["Go to", "Quick actions", "Products", "Sales", "Search"]);
      expect(groups[2]?.items).toEqual([
        { id: "product:p1", kind: "product", title: "Pro widget", href: "/products/p1/edit" },
      ]);
      expect(groups[4]?.items).toEqual([
        { id: "search:sales", kind: "search", title: "Search sales for “pro”", href: "/customers?query=pro" },
        { id: "search:products", kind: "search", title: "Search products for “pro”", href: "/products?query=pro" },
      ]);
    });

    it("still offers the search rows when a request failed", () => {
      expect(titles(build("zz", { products: null, sales: null }))).toEqual(["Search"]);
    });

    it("lists a sale by the buyer's name, or by email when there is no name", () => {
      const groups = build("zz", { products: [], sales: [ada, { ...ada, id: "s2", name: "" }] });

      expect(groups[0]?.items).toEqual([
        {
          id: "sale:s1",
          kind: "sale",
          title: "Ada Prosser",
          detail: "ada@example.com · Pro widget",
          href: "/customers/sale/s1",
        },
        // The email is the title, so it is not repeated underneath.
        { id: "sale:s2", kind: "sale", title: "ada@example.com", detail: "Pro widget", href: "/customers/sale/s1" },
      ]);
    });

    it("encodes the query in the search rows' links", () => {
      const search = build("ada+test@example.com", { products: [], sales: [] }).at(-1);

      expect(search?.items[0]?.href).toBe("/customers?query=ada%2Btest%40example.com");
    });

    // The server answers nothing for one character, so offering to search for it would lead nowhere.
    it("offers no search rows for a single character", () => {
      expect(titles(build("z", { products: [], sales: [] }))).toEqual([]);
    });
  });
});

describe("the active row", () => {
  const items: OmnibarItem[] = ["a", "b", "c"].map((id) => ({ id, kind: "page", title: id, href: `/${id}` }));

  it("stays on the same row when rows are added below it", () => {
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
