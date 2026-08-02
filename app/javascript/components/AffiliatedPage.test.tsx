// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import AffiliatedPage, { AffiliatedPageProps } from "$app/components/AffiliatedPage";
import { UserAgentProvider } from "$app/components/UserAgent";

beforeAll(() => {
  // The stats cards measure text against the loaded fonts; happy-dom has no FontFaceSet.
  if (!("fonts" in document)) Object.defineProperty(document, "fonts", { value: { ready: Promise.resolve() } });
  // js-routes injects Routes as a global in the app; the layout and the table between them reach for
  // a handful of path helpers whose exact URLs are irrelevant here.
  Object.assign(globalThis, {
    Routes: new Proxy(
      {},
      {
        get: (_target, name: string) =>
          name === "products_affiliated_path"
            ? (id: string) => `/products/affiliated/${id}`
            : () => `/${String(name).replace(/_path$|_url$/u, "")}`,
      },
    ),
  });
});

afterEach(cleanup);

const product = (name: string, affiliateId: string | null) => ({
  product_name: name,
  url: `https://example.gumroad.com/l/${name}`,
  fee_percentage: 1000,
  revenue: 0,
  humanized_revenue: "$0",
  sales_count: 0,
  affiliate_type: "direct_affiliate" as const,
  affiliate_id: affiliateId,
  seller_name: "A seller",
});

const props: AffiliatedPageProps = {
  pagination: { page: 1, pages: 1 },
  affiliated_products: [product("stale", "abc123"), product("other", "def456")],
  stats: { total_revenue: 0, total_sales: 0, total_products: 2, total_affiliated_creators: 1 },
  global_affiliates_data: {
    global_affiliate_id: null,
    global_affiliate_sales: null,
    cookie_expiry_days: 7,
    affiliate_query_param: "affiliate_id",
  },
  archived_tab_visible: false,
  affiliates_disabled_reason: null,
};

const removeButtons = () => screen.queryAllByRole("button", { name: /^Remove yourself as an affiliate for /u });

describe("AffiliatedPage", () => {
  it("drops a row the server says is already gone even when the refresh fails", async () => {
    // The removal 404s (another tab already removed it) and the follow-up refresh then fails, which
    // is the case where loadAffiliatedProducts keeps whatever is on screen.
    vi.stubGlobal(
      "fetch",
      vi.fn((_url: string, init?: RequestInit) =>
        Promise.resolve(
          init?.method === "DELETE"
            ? new Response("<html>The page you were looking for doesn't exist.</html>", {
                status: 404,
                headers: { "content-type": "text/html" },
              })
            : new Response("<html>Something went wrong.</html>", {
                status: 500,
                headers: { "content-type": "text/html" },
              }),
        ),
      ),
    );

    render(
      <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
        <AffiliatedPage {...props} />
      </UserAgentProvider>,
    );
    expect(removeButtons()).toHaveLength(2);

    const staleRemove = removeButtons()[0];
    if (!staleRemove) throw new Error("expected a Remove button on the stale row");
    fireEvent.click(staleRemove);
    fireEvent.click(screen.getByRole("button", { name: "Yes, remove me" }));

    await waitFor(() => expect(screen.queryByRole("button", { name: "Yes, remove me" })).toBeNull());
    // The stale row is gone with its Remove action; the surviving affiliation is untouched.
    await waitFor(() => expect(removeButtons()).toHaveLength(1));
    expect(screen.queryByText("stale")).toBeNull();
    expect(screen.getByText("other")).toBeTruthy();
  });
});
