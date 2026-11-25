// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, renderHook, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { type NavItem } from "$app/components/client-components/Nav";
import { HeaderNav, useWrappedChildren } from "$app/components/client-components/Nav/header";
import { CurrentSellerProvider, type CurrentSeller } from "$app/components/CurrentSeller";
import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { LoggedInUserProvider, type LoggedInUser } from "$app/components/LoggedInUser";

vi.mock("@inertiajs/react", () => ({
  Link: ({
    children,
    prefetch: _prefetch,
    method: _method,
    ...props
  }: React.ComponentProps<"a"> & { prefetch?: unknown; method?: string }) => <a {...props}>{children}</a>,
  router: { on: () => () => undefined, visit: () => undefined },
}));

beforeAll(() => {
  const url = (path: string) => () => path;
  Object.assign(globalThis, {
    Routes: {
      settings_main_url: url("/settings/main"),
      settings_team_url: url("/settings/team"),
      help_center_root_url: url("/help"),
      logout_url: url("/logout"),
    },
  });
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

const item = (key: string, text: string, extra: Partial<NavItem> = {}): NavItem => ({
  key,
  text,
  keywords: "",
  visible: true,
  href: `/${key}`,
  icon: <svg data-icon={key} />,
  ...extra,
});
const links = [
  item("dashboard", "Home", { exactHrefMatch: true }),
  item("products", "Products"),
  item("customers", "Sales"),
];
const more = [item("workflows", "Workflows"), item("communities", "Community")];
const actions = [
  { id: "new-product", title: "New product", href: "/products/new" },
  { id: "new-email", title: "New email", href: "/emails/new" },
  { id: "new-workflow", title: "New workflow", href: "/workflows/new" },
];

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
  legalGuardianUnsupported: false,
  isNameInvalidForEmailDelivery: false,
  profileBackgroundColor: "#ffffff",
  profileHighlightColor: "#000000",
  profileFont: "ABC Favorit",
};
const user: LoggedInUser = {
  id: "1",
  email: "seller@example.com",
  name: "Gum",
  avatarUrl: "/avatar.png",
  confirmed: true,
  teamMemberships: [],
  canCreateBrandAccount: false,
  hasPayoutSetupToPort: false,
  canPortBankPayoutSetup: true,
  willCopyBankPayout: false,
  promotedNavItems: [],
  lazyLoadOffscreenDiscoverImages: false,
  headerNav: true,
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
  },
};

const renderHeader = (props: Partial<React.ComponentProps<typeof HeaderNav>> = {}, path = "/products") => {
  window.history.replaceState({}, "", path);
  const onOpenSearch = vi.fn();
  render(
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
          <HeaderNav links={links} more={more} actions={actions} homeHref="/" onOpenSearch={onOpenSearch} {...props} />
        </CurrentSellerProvider>
      </LoggedInUserProvider>
    </DomainSettingsProvider>,
  );
  return { onOpenSearch, nav: screen.getByRole("navigation", { name: "Main" }) };
};
const menuItems = () => screen.getAllByRole("menuitem").map((entry) => entry.textContent);

describe("HeaderNav", () => {
  it("lists the destinations as text, in the order given, with no icons", () => {
    const { nav } = renderHeader();

    const shown = ["Home", "Products", "Sales"].map((name) => within(nav).getByRole("link", { name }));
    expect(shown.map((link) => link.getAttribute("href"))).toEqual(["/dashboard", "/products", "/customers"]);
    expect(nav.querySelector("[data-icon]")).toBeNull();
  });

  it("marks the page being viewed", () => {
    const { nav } = renderHeader();

    expect(within(nav).getByRole("link", { name: "Products" }).getAttribute("aria-current")).toBe("page");
    expect(within(nav).getByRole("link", { name: "Sales" }).getAttribute("aria-current")).toBeNull();
  });

  it("opens search from the field in the middle", () => {
    const { onOpenSearch, nav } = renderHeader();

    fireEvent.click(within(nav).getByRole("button", { name: "Search" }));

    expect(onOpenSearch).toHaveBeenCalledTimes(1);
  });

  describe("More", () => {
    it("holds the destinations that are not in the bar", () => {
      const { nav } = renderHeader();

      fireEvent.click(within(nav).getByRole("button", { name: "More" }));

      expect(menuItems()).toEqual(["Workflows", "Community"]);
    });

    it("runs a destination's own handler and closes when one is chosen", () => {
      const onClick = vi.fn();
      const { nav } = renderHeader({ more: [item("communities", "Community", { onClick })] });

      fireEvent.click(within(nav).getByRole("button", { name: "More" }));
      fireEvent.click(screen.getByRole("menuitem", { name: "Community" }));

      expect(onClick).toHaveBeenCalledTimes(1);
      expect(screen.queryByRole("menuitem")).toBeNull();
    });

    it("is left out when every destination fits in the bar", () => {
      const { nav } = renderHeader({ more: [] });

      expect(within(nav).queryByRole("button", { name: "More" })).toBeNull();
    });

    // The row wraps and clips: a link that did not fit is on a later line.
    it("takes in the links the bar had no room for, ahead of the rest", () => {
      vi.spyOn(HTMLElement.prototype, "offsetTop", "get").mockImplementation(function (this: HTMLElement) {
        return this.dataset.key === "customers" ? 40 : 0;
      });
      const { nav } = renderHeader();

      const clipped = nav.querySelector('[data-key="customers"]');
      expect(clipped?.getAttribute("aria-hidden")).toBe("true");
      expect(clipped?.getAttribute("tabindex")).toBe("-1");
      fireEvent.click(within(nav).getByRole("button", { name: "More" }));
      expect(menuItems()).toEqual(["Sales", "Workflows", "Community"]);
    });
  });

  describe("create button", () => {
    it("goes straight to the first thing the user may create", () => {
      const { nav } = renderHeader();

      expect(within(nav).getByRole("link", { name: "New product" }).getAttribute("href")).toBe("/products/new");
    });

    it("keeps the other things to create behind the arrow", () => {
      const { nav } = renderHeader();

      fireEvent.click(within(nav).getByRole("button", { name: "Create something else" }));

      expect(menuItems()).toEqual(["New email", "New workflow"]);
      expect(screen.getByRole("menuitem", { name: "New email" }).getAttribute("href")).toBe("/emails/new");
    });

    it("has no arrow when there is one thing to create, and is absent when there is none", () => {
      const { nav } = renderHeader({ actions: actions.slice(1, 2) });
      expect(within(nav).getByRole("link", { name: "New email" })).toBeTruthy();
      expect(within(nav).queryByRole("button", { name: "Create something else" })).toBeNull();
      cleanup();

      const { nav: bare } = renderHeader({ actions: [] });
      expect(within(bare).queryByRole("link", { name: /^New /u })).toBeNull();
    });
  });

  it("puts the account menu at the right end, with Help and Logout in it", () => {
    const { nav } = renderHeader();

    fireEvent.click(within(nav).getByRole("button", { name: "Gum account" }));

    expect(menuItems()).toEqual(["Settings", "Teams", "Help", "Logout"]);
  });
});

describe("useWrappedChildren", () => {
  const Row = ({ keys, onWrapped }: { keys: string[]; onWrapped: (wrapped: string[]) => void }) => {
    const [ref, wrapped] = useWrappedChildren(keys);
    React.useEffect(() => onWrapped(wrapped), [wrapped]);
    return (
      <div ref={ref}>
        {keys.map((key) => (
          <span key={key} data-key={key} />
        ))}
      </div>
    );
  };

  it("reports the children on a later line than the first", () => {
    vi.spyOn(HTMLElement.prototype, "offsetTop", "get").mockImplementation(function (this: HTMLElement) {
      return ["c", "d"].includes(this.dataset.key ?? "") ? 40 : 0;
    });
    const onWrapped = vi.fn();

    render(<Row keys={["a", "b", "c", "d"]} onWrapped={onWrapped} />);

    expect(onWrapped).toHaveBeenLastCalledWith(["c", "d"]);
  });

  it("reports none when the row has no element to measure", () => {
    const { result } = renderHook(() => useWrappedChildren(["a"]));

    act(() => undefined);

    expect(result.current[1]).toEqual([]);
  });
});
