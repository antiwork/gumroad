// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CurrentSellerProvider, type CurrentSeller } from "$app/components/CurrentSeller";
import { DashboardPage, type DashboardPageProps } from "$app/components/DashboardPage";
import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { LoggedInUserProvider, type LoggedInUser } from "$app/components/LoggedInUser";
import { UserAgentProvider } from "$app/components/UserAgent";

vi.mock("@inertiajs/react", () => ({
  Link: ({ href, children }: { href?: string; children?: React.ReactNode }) => <a href={href}>{children}</a>,
  router: { on: () => () => undefined },
  usePage: () => ({ props: {}, url: "/dashboard", component: "Dashboard", version: null }),
}));

// Stats measures text with document.fonts + canvas, neither of which happy-dom implements.
vi.mock("$app/components/Stats", () => ({ Stats: () => null }));

// The dashboard builds its getting-started links at module scope, so Routes has to be on globalThis
// before the component is imported.
vi.hoisted(() => {
  const url = (path: string) => () => path;
  Object.assign(globalThis, {
    Routes: {
      dashboard_dismiss_getting_started_checklist_path: url("/dashboard/dismiss_getting_started_checklist"),
      dashboard_dismiss_gumhead_promo_path: url("/dashboard/dismiss_gumhead_promo"),
      dashboard_download_tax_form_path: url("/dashboard/download_tax_form"),
      dashboard_path: url("/dashboard"),
      edit_link_url: url("/links/:id/edit"),
      followers_path: url("/followers"),
      new_product_path: url("/products/new"),
      posts_path: url("/posts"),
      profile_path: url("/profile"),
      sales_dashboard_path: url("/sales"),
      settings_payments_path: url("/settings/payments"),
      settings_social_connections_path: url("/settings/social_connections"),
      tax_center_path: url("/tax_center"),
    },
  });
});

afterEach(cleanup);

const loggedInUser: LoggedInUser = {
  id: "1",
  email: "seller@example.com",
  name: "Seller",
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
  lazyLoadOffscreenDiscoverImages: false,
};

const minor: CurrentSeller = {
  id: "1",
  email: "seller@example.com",
  name: "Seller",
  subdomain: "seller",
  avatarUrl: "",
  isBuyer: false,
  timeZone: { name: "UTC", offset: 0 },
  has_published_products: false,
  can_publish_products: true,
  publishBlockedReason: null,
  noPayoutRailInComplianceCountry: false,
  legalGuardianRequirementMet: false,
  legalGuardianUnsupported: false,
  isNameInvalidForEmailDelivery: false,
  profileBackgroundColor: "#ffffff",
  profileHighlightColor: "#000000",
  profileFont: "ABC Favorit",
};

const props: DashboardPageProps = {
  name: "Seller",
  has_sale: false,
  getting_started_stats: {},
  getting_started_dismissed: true,
  social_connections: [],
  sales: [],
  balances: { balance: "$0", last_seven_days_sales_total: "$0", last_28_days_sales_total: "$0", total: "$0" },
  activity_items: [],
  tax_forms: {},
  show_1099_download_notice: false,
  tax_center_enabled: false,
  gumhead: null,
};

const renderDashboard = (currentSeller: CurrentSeller) =>
  render(
    <LoggedInUserProvider value={loggedInUser}>
      <CurrentSellerProvider value={currentSeller}>
        <DomainSettingsProvider
          value={{
            scheme: "https",
            appDomain: "app.test.gumroad.com",
            rootDomain: "test.gumroad.com",
            shortDomain: "test.gumroad.com",
            discoverDomain: "discover.test.gumroad.com",
            thirdPartyAnalyticsDomain: "test.gumroad.com",
            apiDomain: "api.test.gumroad.com",
          }}
        >
          <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
            <DashboardPage {...props} />
          </UserAgentProvider>
        </DomainSettingsProvider>
      </CurrentSellerProvider>
    </LoggedInUserProvider>,
  );

describe("DashboardPage under-18 banner", () => {
  // The unsupported branch is the whole point of the split: a minor whose country has no guardian path
  // must not be sent to a payments page that tells them a guardian cannot help.
  it("points a minor outside the guardian countries at payouts starting at 18", () => {
    renderDashboard({ ...minor, legalGuardianUnsupported: true });

    expect(
      screen.getByText(/cannot verify a seller under 18 in your country, even with a legal guardian/u),
    ).toBeTruthy();
    expect(screen.getByRole("link", { name: "Review your payout setup" }).getAttribute("href")).toBe(
      "/settings/payments",
    );
    expect(screen.queryByRole("link", { name: "Add a guardian" })).toBeNull();
  });

  it("still asks a US minor with no guardian on file to add one", () => {
    renderDashboard({ ...minor, legalGuardianUnsupported: false });

    expect(screen.getByText(/a parent or guardian needs to be added to your account/u)).toBeTruthy();
    expect(screen.getByRole("link", { name: "Add a guardian" }).getAttribute("href")).toBe("/settings/payments");
    expect(screen.queryByText(/cannot verify a seller under 18/u)).toBeNull();
  });
});
