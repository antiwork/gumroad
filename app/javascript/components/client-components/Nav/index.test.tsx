// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import { Nav } from "$app/components/client-components/Nav";
import { CurrentSellerProvider, type CurrentSeller } from "$app/components/CurrentSeller";
import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { LoggedInUserProvider, type LoggedInUser } from "$app/components/LoggedInUser";

// `prefetch` is a behavior of Inertia's Link, not a DOM attribute, so the only way to assert on it
// is to capture the props each row is rendered with.
const linkPropsByText = new Map<string, { prefetch?: unknown }>();

vi.mock("@inertiajs/react", () => ({
  Link: ({
    children,
    prefetch,
    title,
    href,
    className,
    onClick,
    "aria-current": ariaCurrent,
  }: {
    children?: React.ReactNode;
    prefetch?: unknown;
    title?: string;
    href?: string;
    className?: string;
    onClick?: (event: React.MouseEvent) => void;
    "aria-current"?: "page" | undefined;
  }) => {
    if (title !== undefined) linkPropsByText.set(title, { prefetch });
    return (
      <a href={href} title={title} className={className} onClick={onClick} aria-current={ariaCurrent}>
        {children}
      </a>
    );
  },
  router: { on: () => () => undefined },
}));

beforeEach(() => linkPropsByText.clear());

// The nav builds every href through js-routes, which the app injects as a global.
beforeAll(() => {
  const url = (path: string) => () => path;
  Object.assign(globalThis, {
    Routes: {
      root_url: url("/"),
      dashboard_url: url("/dashboard"),
      discover_url: url("/discover"),
      agent_url: url("/agent"),
      profile_url: url("/profile"),
      pages_url: url("/pages"),
      products_url: url("/products"),
      collaborators_url: url("/collaborators"),
      checkout_discounts_url: url("/checkout/discounts"),
      checkout_form_url: url("/checkout/form"),
      checkout_upsells_url: url("/checkout/upsells"),
      emails_url: url("/emails"),
      followers_url: url("/followers"),
      workflows_url: url("/workflows"),
      customers_url: url("/customers"),
      sales_dashboard_url: url("/dashboard/sales"),
      audience_dashboard_url: url("/dashboard/audience"),
      dashboard_utm_links_url: url("/dashboard/utm_links"),
      churn_dashboard_url: url("/dashboard/churn"),
      affiliates_url: url("/affiliates"),
      balance_url: url("/payouts"),
      communities_path: url("/communities"),
      library_url: url("/library"),
      wishlists_url: url("/wishlists"),
      reviews_url: url("/reviews"),
      settings_main_url: url("/settings/main"),
      settings_team_url: url("/settings/team"),
      help_center_root_url: url("/help"),
      logout_url: url("/logout"),
    },
  });
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

const seller: CurrentSeller = {
  id: "1",
  email: "seller@example.com",
  name: "Gum",
  subdomain: "gum",
  avatarUrl: "/avatar.png",
  isBuyer: false,
  timeZone: { name: "UTC", offset: 0 },
  has_published_products: true,
  can_publish_products: true,
  publishBlockedReason: null,
  noPayoutRailInComplianceCountry: false,
  legalGuardianRequirementMet: true,
  isNameInvalidForEmailDelivery: false,
  profileBackgroundColor: "#ffffff",
  profileHighlightColor: "#000000",
  profileFont: "ABC Favorit",
};

// Every policy is granted so the tests isolate promotion from authorization; the one test that
// cares about a denied row turns its policy off explicitly.
const buildUser = (promotedNavItems: string[]): LoggedInUser => ({
  id: "1",
  email: "seller@example.com",
  name: "Gum",
  avatarUrl: "/avatar.png",
  confirmed: true,
  teamMemberships: [],
  canCreateBrandAccount: false,
  hasPayoutSetupToPort: false,
  promotedNavItems,
  lazyLoadOffscreenDiscoverImages: false,
  policies: {
    affiliate_requests_onboarding_form: { update: true },
    direct_affiliate: { create: true, update: true },
    collaborator: { create: true, update: true },
    product: { create: true },
    product_review_response: { update: true },
    balance: { index: true, export: true },
    checkout_offer_code: { create: true },
    checkout_form: { update: true },
    upsell: { create: true },
    settings_payments_user: { show: true },
    settings_main_user: { update_username: true },
    settings_profile: { manage_social_connections: true, update: true },
    settings_third_party_analytics_user: { update: true },
    installment: { create: true },
    workflow: { create: true },
    utm_link: { index: true },
    community: { index: true },
    churn: { show: true },
    page: { index: true, create: true },
    user: { view_store_agent: true, use_store_agent: true },
  },
});

// Mirrors DashboardNav::PROMOTABLE_ITEMS.
const ALL_PROMOTABLE = [
  "agent",
  "profile",
  "pages",
  "collaborators",
  "checkout",
  "emails",
  "workflows",
  "analytics",
  "affiliates",
  "community",
  "library",
];

const renderNav = ({
  promoted = [],
  path = "/dashboard",
  withUser,
}: { promoted?: string[]; path?: string; withUser?: (user: LoggedInUser) => void } = {}) => {
  window.history.replaceState({}, "", path);
  const user = buildUser(promoted);
  withUser?.(user);
  return render(
    <DomainSettingsProvider
      value={{
        scheme: "https",
        appDomain: "gumroad.com",
        rootDomain: "gumroad.com",
        shortDomain: "gum.co",
        discoverDomain: "discover.gumroad.com",
        thirdPartyAnalyticsDomain: "analytics.gumroad.com",
        apiDomain: "api.gumroad.com",
      }}
    >
      <LoggedInUserProvider value={user}>
        <CurrentSellerProvider value={seller}>
          <Nav title="Dashboard" />
        </CurrentSellerProvider>
      </LoggedInUserProvider>
    </DomainSettingsProvider>,
  );
};

// Scoped to the scroll region so the header logo and the pinned footer (Help, account popover)
// don't show up as nav rows.
const navScrollRegion = () => {
  const region = screen.getByRole("navigation", { name: "Main" }).querySelector(".overflow-y-auto");
  if (!(region instanceof HTMLElement)) throw new Error("Expected the nav links to have a scroll region");
  return region;
};

const navLinkNames = () =>
  [...navScrollRegion().querySelectorAll("a")]
    .filter((link) => !link.closest("[inert], [hidden], [aria-hidden='true']"))
    .map((link) => link.textContent.trim())
    .filter(Boolean);

describe("dashboard nav progressive disclosure", () => {
  it("shows only the core rows to a seller who has used nothing", () => {
    renderNav();

    expect(navLinkNames()).toEqual(["Home", "Products", "Sales", "Payouts", "Discover"]);
    expect(screen.getByRole("button", { name: "Everything else" })).toBeTruthy();
  });

  it("keeps every other destination reachable under Everything else", () => {
    renderNav();

    expect(screen.queryByRole("link", { name: "Workflows" })).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: "Everything else" }));

    for (const name of ["Agent", "Profile", "Pages", "Collaborators", "Checkout", "Emails", "Workflows", "Analytics"]) {
      expect(screen.getByRole("link", { name })).toBeTruthy();
    }
  });

  it("renders a promoted destination as a top-level row", () => {
    renderNav({ promoted: ["workflows", "analytics"] });

    expect(navLinkNames()).toEqual(["Home", "Products", "Workflows", "Sales", "Analytics", "Payouts", "Discover"]);
  });

  it("renders a promoted Library above Discover, inside the same section as every other row", () => {
    renderNav({ promoted: ["library"] });

    const names = navLinkNames();
    expect(names.indexOf("Library")).toBeLessThan(names.indexOf("Discover"));
    // Same <section> as the core rows — Library and Discover are not split off behind a gap.
    const section = (name: string) => within(navScrollRegion()).getByRole("link", { name }).closest("section");
    expect(section("Library")).toBe(section("Home"));
    expect(section("Discover")).toBe(section("Home"));
    expect(within(navScrollRegion()).getByRole("button", { name: "Everything else" }).closest("section")).toBe(
      section("Home"),
    );
  });

  it("keeps the page being viewed out of the overflow even before its promotion is recorded", () => {
    // The promotion write happens on the same request that renders this page, so without this the
    // seller would watch the row they just opened sit inside "Everything else".
    renderNav({ path: "/workflows" });

    expect(screen.getByRole("link", { name: "Workflows" })).toBeTruthy();
  });

  it("keeps the disclosure control inside the sidebar box, like every other row", () => {
    // `all-unset` clears box-sizing, so a `w-full` + `px-6` control renders 48px wider than the
    // 208px sidebar and the overhang is only hidden by the nav's overflow clip.
    renderNav();

    const control = screen.getByRole("button", { name: "Everything else" });
    expect(control.className).toContain("box-border");
  });

  it("turns a chevron when Everything else opens, instead of a static ellipsis", () => {
    renderNav();

    const control = screen.getByRole("button", { name: "Everything else" });
    const chevron = control.querySelector("svg");
    expect(chevron).not.toBeNull();
    expect(chevron?.classList.contains("rotate-90")).toBe(false);
    expect(chevron?.classList.contains("transition-transform")).toBe(true);

    fireEvent.click(control);

    expect(control.getAttribute("aria-expanded")).toBe("true");
    expect(control.querySelector("svg")?.classList.contains("rotate-90")).toBe(true);
  });

  it("slides the extra rows open instead of snapping them in", () => {
    renderNav();

    const control = screen.getByRole("button", { name: "Everything else" });
    const panel = document.getElementById(control.getAttribute("aria-controls") ?? "");
    expect(panel?.className).toContain("grid-rows-[0fr]");
    expect(panel?.className).toContain("transition-[grid-template-rows]");

    fireEvent.click(control);

    expect(panel?.className).toContain("grid-rows-[1fr]");
  });

  it("scrolls the disclosure to the top of the nav so the new rows are on screen", () => {
    vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback) => {
      cb(0);
      return 0;
    });
    renderNav();

    const region = navScrollRegion();
    const scrollTo = vi.fn();
    region.scrollTo = scrollTo;
    Object.defineProperty(region, "scrollTop", { configurable: true, value: 40, writable: true });
    vi.spyOn(region, "getBoundingClientRect").mockReturnValue({ top: 80 } as DOMRect);
    const control = screen.getByRole("button", { name: "Everything else" });
    vi.spyOn(control, "getBoundingClientRect").mockReturnValue({ top: 320 } as DOMRect);

    fireEvent.click(control);

    expect(scrollTo).toHaveBeenCalledWith({ top: 280, behavior: "smooth" });

    // The rAF scroll runs while the grid is still ~0fr and clamps, so the same scroll must be
    // re-issued once the grid-template-rows transition has given the rows their height.
    const panel = document.getElementById(control.getAttribute("aria-controls") ?? "");
    if (!panel) throw new Error("Expected the disclosure panel to exist");
    // happy-dom's TransitionEvent constructor drops propertyName, so define it on a plain Event.
    const transitionEnd = new Event("transitionend", { bubbles: true });
    Object.defineProperty(transitionEnd, "propertyName", { value: "grid-template-rows" });
    fireEvent(panel, transitionEnd);

    expect(scrollTo).toHaveBeenCalledTimes(2);
    expect(scrollTo).toHaveBeenLastCalledWith({ top: 280, behavior: "smooth" });
  });

  it("scrolls without animation when the user prefers reduced motion", () => {
    vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback) => {
      cb(0);
      return 0;
    });
    vi.stubGlobal("matchMedia", vi.fn().mockReturnValue({ matches: true }));
    renderNav();

    const region = navScrollRegion();
    const scrollTo = vi.fn();
    region.scrollTo = scrollTo;
    Object.defineProperty(region, "scrollTop", { configurable: true, value: 40, writable: true });
    vi.spyOn(region, "getBoundingClientRect").mockReturnValue({ top: 80 } as DOMRect);
    const control = screen.getByRole("button", { name: "Everything else" });
    vi.spyOn(control, "getBoundingClientRect").mockReturnValue({ top: 320 } as DOMRect);

    fireEvent.click(control);

    expect(scrollTo).toHaveBeenCalledWith({ top: 280, behavior: "auto" });
  });

  it("keeps the collapsed overflow inert so its rows are unreachable until it opens", () => {
    renderNav();

    const control = screen.getByRole("button", { name: "Everything else" });
    const panel = document.getElementById(control.getAttribute("aria-controls") ?? "");
    const wrapper = panel?.querySelector(".overflow-hidden");
    if (!(wrapper instanceof HTMLElement)) throw new Error("Expected the overflow wrapper to exist");
    expect(wrapper.hasAttribute("inert")).toBe(true);

    fireEvent.click(control);

    expect(wrapper.hasAttribute("inert")).toBe(false);
  });

  it("drops Everything else once nothing is left in it", () => {
    renderNav({ promoted: ALL_PROMOTABLE });

    expect(screen.queryByRole("button", { name: "Everything else" })).toBeNull();
    expect(screen.getByRole("link", { name: "Analytics" })).toBeTruthy();
  });

  it("does not render a row the user's policies forbid, even inside the overflow", () => {
    renderNav({
      promoted: ["community"],
      withUser: (user) => {
        user.policies.community.index = false;
      },
    });

    // Promotion records that the user opened a destination; it never grants access to one.
    fireEvent.click(screen.getByRole("button", { name: "Everything else" }));
    expect(screen.queryByRole("link", { name: "Community" })).toBeNull();
  });

  it("does not prefetch overflow rows, so the click that earns a row reaches the server", () => {
    renderNav();

    fireEvent.click(screen.getByRole("button", { name: "Everything else" }));

    // Inertia prefetches on hover and a later click ADOPTS that response instead of issuing its own
    // request — so a prefetching overflow row could be clicked without the server ever seeing the
    // visit that is supposed to promote it.
    expect(linkPropsByText.get("Workflows")?.prefetch).toBe(false);
    // A promoted row sits at the top level, where prefetching costs nothing: promoting an
    // already-recorded destination is a no-op.
    expect(linkPropsByText.get("Products")?.prefetch).not.toBe(false);
  });
});
