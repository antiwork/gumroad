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
    prefetch,
    method: _method,
    ...props
  }: React.ComponentProps<"a"> & { prefetch?: unknown; method?: string }) => (
    <a data-prefetch={String(prefetch ?? false)} {...props}>
      {children}
    </a>
  ),
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
  vi.unstubAllGlobals();
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
      // Invisible leaves the tab order, the accessibility tree and find-in-page, and is still measured.
      expect(clipped?.className.split(" ")).toContain("invisible");
      fireEvent.click(within(nav).getByRole("button", { name: "More" }));
      expect(menuItems()).toEqual(["Sales", "Workflows", "Community"]);
    });
  });

  describe("More, beyond its list", () => {
    it("is marked, with its row, when it holds the page being viewed", () => {
      const { nav } = renderHeader({}, "/workflows");

      const trigger = within(nav).getByRole("button", { name: "More" });
      expect(trigger.className).toContain("text-accent");
      fireEvent.click(trigger);
      expect(screen.getByRole("menuitem", { name: "Workflows" }).getAttribute("aria-current")).toBe("page");
    });

    // A prefetched visit never reaches the server, which is what promotes a destination out of More.
    it("leaves prefetching to the bar's links", () => {
      const { nav } = renderHeader();

      expect(within(nav).getByRole("link", { name: "Products" }).dataset.prefetch).toBe("hover");
      fireEvent.click(within(nav).getByRole("button", { name: "More" }));
      expect(screen.getByRole("menuitem", { name: "Workflows" }).dataset.prefetch).toBe("false");
    });

    it("takes in a link when the bar is resized and it no longer fits", () => {
      const resize: { run: () => void } = { run: () => undefined };
      vi.stubGlobal(
        "ResizeObserver",
        class {
          constructor(callback: () => void) {
            resize.run = callback;
          }
          observe() {}
          disconnect() {}
        },
      );
      let clippedKey = "";
      vi.spyOn(HTMLElement.prototype, "offsetTop", "get").mockImplementation(function (this: HTMLElement) {
        return this.dataset.key === clippedKey ? 40 : 0;
      });
      const { nav } = renderHeader();

      clippedKey = "customers";
      act(() => resize.run());

      expect(nav.querySelector('[data-key="customers"]')?.className.split(" ")).toContain("invisible");
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

    // PopoverTrigger strips the outline from its child; the arrow puts one back.
    it("shows a focus ring on the arrow", () => {
      const { nav } = renderHeader();

      const classes = within(nav).getByRole("button", { name: "Create something else" }).className.split(" ");
      expect(classes).toContain("focus-visible:outline-solid");
      expect(classes).not.toContain("focus-visible:outline-none");
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

  // The nav outlives the visit, so an open menu would sit over the page it led to.
  it("closes the account menu once a row is chosen", () => {
    const { nav } = renderHeader();

    fireEvent.click(within(nav).getByRole("button", { name: "Gum account" }));
    fireEvent.click(screen.getByRole("menuitem", { name: "Settings" }));

    expect(screen.queryByRole("menuitem")).toBeNull();
  });
});

describe("HeaderNav rows", () => {
  const rows = (nav: HTMLElement) => {
    const [top, links] = [...nav.children].filter((child): child is HTMLDivElement => child instanceof HTMLDivElement);
    if (!top || !links) throw new Error("Expected two rows in the header");
    return { top, links };
  };

  it("puts the links on their own row under the search", () => {
    const { nav } = renderHeader();

    const { top, links } = rows(nav);
    expect(within(top).getByRole("button", { name: "Search" })).toBeTruthy();
    expect(within(top).queryByRole("link", { name: "Products" })).toBeNull();
    expect(within(links).getByRole("link", { name: "Products" })).toBeTruthy();
  });

  it("gives search and the create button the same height", () => {
    const { nav } = renderHeader();

    expect(within(nav).getByRole("button", { name: "Search" }).className.split(" ")).toContain("h-12");
    expect(within(nav).getByRole("link", { name: "New product" }).parentElement?.className.split(" ")).toContain(
      "h-12",
    );
  });

  // On a very wide screen an uncapped field would run most of the way across it.
  it("caps the search field's width", () => {
    const { nav } = renderHeader();

    expect(within(nav).getByRole("button", { name: "Search" }).parentElement?.className.split(" ")).toContain(
      "max-w-3xl",
    );
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
