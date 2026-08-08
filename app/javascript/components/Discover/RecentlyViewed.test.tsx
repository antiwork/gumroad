// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { PLACEHOLDER_CARD_PRODUCT } from "$app/utils/cart";

import { RecentlyViewed, RecentlyViewedProps } from "$app/components/Discover/RecentlyViewed";
import { LoggedInUser, LoggedInUserProvider } from "$app/components/LoggedInUser";

const productAt = (id: string, name: string, viewed_at: string) => ({
  ...PLACEHOLDER_CARD_PRODUCT,
  id,
  name,
  viewed_at,
});

const asUser = (id: string): LoggedInUser => ({
  id,
  email: null,
  name: null,
  avatarUrl: "",
  confirmed: true,
  teamMemberships: [],
  canCreateBrandAccount: false,
  hasPayoutSetupToPort: false,
  policies: {
    affiliate_requests_onboarding_form: { update: false },
    direct_affiliate: { create: false, update: false },
    collaborator: { create: false, update: false },
    product: { create: false },
    product_review_response: { update: false },
    balance: { index: false, export: false },
    checkout_offer_code: { create: false },
    checkout_form: { update: false },
    upsell: { create: false },
    settings_payments_user: { show: false },
    settings_main_user: { update_username: false },
    settings_profile: { manage_social_connections: false, update: false },
    settings_third_party_analytics_user: { update: false },
    installment: { create: false },
    workflow: { create: false },
    utm_link: { index: false },
    community: { index: false },
    churn: { show: false },
    page: { index: false, create: false },
    user: { view_store_agent: false, use_store_agent: false },
  },
  promotedNavItems: [],
  isGumroadAdmin: false,
  isImpersonating: false,
  lazyLoadOffscreenDiscoverImages: false,
});

const renderRow = (data: RecentlyViewedProps | null, user: LoggedInUser | null = null) =>
  render(
    <LoggedInUserProvider value={user}>
      <RecentlyViewed data={data} />
    </LoggedInUserProvider>,
  );

afterEach(() => {
  cleanup();
  localStorage.clear();
});

beforeEach(() => {
  localStorage.clear();
});

describe("RecentlyViewed", () => {
  it("renders nothing without data", () => {
    renderRow(null);
    expect(screen.queryByText("Recently viewed")).toBeNull();
  });

  it("clear hides only products viewed before the cutoff, not ones viewed after it", () => {
    const older = productAt("older", "Older Product", "2026-01-01T00:00:00.000Z");
    const data: RecentlyViewedProps = { products: [older] };
    const { rerender } = renderRow(data);
    expect(screen.queryByText("Older Product")).not.toBeNull();

    screen.getByText("Clear").click();
    rerender(
      <LoggedInUserProvider value={null}>
        <RecentlyViewed data={data} />
      </LoggedInUserProvider>,
    );
    expect(screen.queryByText("Older Product")).toBeNull();

    // A view recorded after the clear (server refresh bumps the row) must survive it — the bug
    // T-Rex/greptile flagged was comparing only the newest view, which resurrected every
    // product including ones still legitimately cleared.
    const newer = productAt("newer", "Newer Product", new Date(Date.now() + 60_000).toISOString());
    rerender(
      <LoggedInUserProvider value={null}>
        <RecentlyViewed data={{ products: [older, newer] }} />
      </LoggedInUserProvider>,
    );
    expect(screen.queryByText("Older Product")).toBeNull();
    expect(screen.queryByText("Newer Product")).not.toBeNull();
  });

  it("clear does not hide a product whose whole-second server timestamp is actually after the cutoff", () => {
    // A raw-string comparison sorts "...:56Z" AFTER "...:56.001Z" (Z > .) even though the
    // whole-second value is the earlier instant. Set the cutoff before mount so the
    // component reads it from storage on init, same as after a real Clear click.
    localStorage.setItem("gr_discover_recently_viewed_cleared_at:anonymous", "2026-08-08T12:34:56.001Z");
    const data: RecentlyViewedProps = { products: [productAt("p", "Product", "2026-08-08T12:34:56Z")] };
    renderRow(data);
    expect(screen.queryByText("Product")).toBeNull();
  });

  it("does not apply one identity's clear cutoff to a different identity on the same browser", () => {
    const oldProduct = productAt("old", "Old Product", "2026-01-01T00:00:00.000Z");
    const { rerender, unmount } = renderRow({ products: [oldProduct] }, asUser("user-a"));
    screen.getByText("Clear").click();
    rerender(
      <LoggedInUserProvider value={asUser("user-a")}>
        <RecentlyViewed data={{ products: [oldProduct] }} />
      </LoggedInUserProvider>,
    );
    expect(screen.queryByText("Old Product")).toBeNull();
    unmount();

    // Different signed-in identity on the same browser, same product viewed earlier than
    // A's clear (a fresh mount, matching the full page load a real sign-in/out triggers) —
    // B's history predates A's clear and must not be hidden by it.
    renderRow({ products: [oldProduct] }, asUser("user-b"));
    expect(screen.queryByText("Old Product")).not.toBeNull();
  });

  it("does not carry a stale cutoff across an in-place identity change (no remount)", () => {
    const product = productAt("p", "Product", "2026-01-01T00:00:00.000Z");
    const { rerender } = renderRow({ products: [product] }, null);
    screen.getByText("Clear").click();
    rerender(
      <LoggedInUserProvider value={null}>
        <RecentlyViewed data={{ products: [product] }} />
      </LoggedInUserProvider>,
    );
    expect(screen.queryByText("Product")).toBeNull();

    // The anonymous visitor signs in without a full page reload (same mounted component,
    // just a new context value) — the signed-in identity has never cleared anything, so
    // its own history must render, not the anonymous cutoff carried over in state.
    rerender(
      <LoggedInUserProvider value={asUser("user-a")}>
        <RecentlyViewed data={{ products: [product] }} />
      </LoggedInUserProvider>,
    );
    expect(screen.queryByText("Product")).not.toBeNull();
  });

  it("does not apply one anonymous browser identity's clear cutoff to a different one sharing the browser", () => {
    const oldProduct = productAt("old", "Old Product", "2026-01-01T00:00:00.000Z");
    renderRow({ products: [oldProduct], anonymous_key: "guid-a" });
    screen.getByText("Clear").click();
    cleanup();

    // A different server-derived anonymous_key (browser GUID cookie replaced, localStorage
    // retained) is a different identity and must not inherit guid A's cutoff — this is the
    // gap a single shared "anonymous" bucket had.
    renderRow({ products: [oldProduct], anonymous_key: "guid-b" });
    expect(screen.queryByText("Old Product")).not.toBeNull();
  });
});
