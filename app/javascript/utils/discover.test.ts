import { describe, expect, test } from "vitest";

import { discoverTitleGenerator, getRootTaxonomy, Taxonomy } from "$app/utils/discover";

const taxonomies: Taxonomy[] = [{ key: "design", slug: "design", label: "Design", parent_key: null }];

describe("discoverTitleGenerator", () => {
  test("keeps the SEO suffix on an unfiltered taxonomy page whose sort is the implicit curated default", () => {
    // Regression for the P1 Greptile caught on gp#7035: parseUrlParams defaults sort to "curated"
    // when curated products exist, and that default gets serialized into the URL, so a bare
    // /design URL was reading as `?sort=curated` and losing the suffix.
    const title = discoverTitleGenerator({ taxonomy: "design" }, taxonomies, "?sort=curated", "curated");
    expect(title).toBe("Design — digital products by independent creators | Gumroad");
  });

  test("drops the SEO suffix when sort is explicitly set to something other than the default", () => {
    const title = discoverTitleGenerator(
      { taxonomy: "design", sort: "best_sellers" },
      taxonomies,
      "?sort=best_sellers",
      "curated",
    );
    expect(title).toBe("Design | Gumroad");
  });

  test("drops the SEO suffix when sort is explicitly set to curated by the user with no curated default", () => {
    // No curated products server-side (defaultSortOrder undefined) means an explicit ?sort=curated
    // in the URL is a real user filter, not the implicit default, and must still disqualify the page.
    const title = discoverTitleGenerator(
      { taxonomy: "design", sort: "curated" },
      taxonomies,
      "?sort=curated",
      undefined,
    );
    expect(title).toBe("Design | Gumroad");
  });

  test("keeps the SEO suffix on a bare taxonomy URL with no query params at all", () => {
    const title = discoverTitleGenerator({ taxonomy: "design" }, taxonomies, "", undefined);
    expect(title).toBe("Design — digital products by independent creators | Gumroad");
  });

  test("uses the Discover landing title on the unfiltered index", () => {
    const title = discoverTitleGenerator({}, taxonomies, "", undefined);
    expect(title).toBe("Discover digital products from independent creators | Gumroad");
  });
});

describe("getRootTaxonomy", () => {
  test("returns the root slug of a known taxonomy path", () => {
    expect(getRootTaxonomy("design/icons")).toBe("design");
    expect(getRootTaxonomy("other")).toBe("other");
  });

  test("returns null for an unknown or missing root", () => {
    expect(getRootTaxonomy("nonsense/icons")).toBeNull();
    expect(getRootTaxonomy("toString")).toBeNull();
    expect(getRootTaxonomy(undefined)).toBeNull();
  });
});
