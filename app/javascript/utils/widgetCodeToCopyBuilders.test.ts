import { describe, expect, it } from "vitest";

import { buildAnalyticsCodeToCopy, permalinkFromProductUrl } from "$app/utils/widgetCodeToCopyBuilders";

describe("permalinkFromProductUrl", () => {
  it("takes the last path segment of a product URL", () => {
    expect(permalinkFromProductUrl("https://example.gumroad.com/l/demo")).toBe("demo");
  });

  it("takes the last path segment of an affiliate URL", () => {
    expect(permalinkFromProductUrl("https://gumroad.com/a/123/demo")).toBe("demo");
  });

  it("returns empty string for an invalid URL", () => {
    expect(permalinkFromProductUrl("not a url")).toBe("");
  });
});

describe("buildAnalyticsCodeToCopy", () => {
  it("builds a drop-in script tagged with the product permalink", () => {
    expect(
      buildAnalyticsCodeToCopy({
        scriptBaseUrl: "https://gumroad.com",
        productUrl: "https://example.gumroad.com/l/demo",
        analyticsToken: "signed-token",
      }),
    ).toBe(
      `<script async src="https://gumroad.com/js/gumroad-analytics.js" data-gumroad-product="demo" data-gumroad-analytics-token="signed-token"></script>`,
    );
  });
});
