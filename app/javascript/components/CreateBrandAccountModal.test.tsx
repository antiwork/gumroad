// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { CreateBrandAccountModal } from "$app/components/CreateBrandAccountModal";
import { LoggedInUserProvider, type LoggedInUser } from "$app/components/LoggedInUser";

const user = (flags: Pick<LoggedInUser, "hasPayoutSetupToPort" | "canPortBankPayoutSetup" | "willCopyBankPayout">): LoggedInUser => ({
  id: "1",
  email: "seller@example.com",
  name: "Seller",
  avatarUrl: "",
  confirmed: true,
  teamMemberships: [],
  canCreateBrandAccount: true,
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
  ...flags,
});

const renderModal = (flags: Pick<LoggedInUser, "hasPayoutSetupToPort" | "canPortBankPayoutSetup" | "willCopyBankPayout">) => {
  render(
    <LoggedInUserProvider value={user(flags)}>
      <CreateBrandAccountModal open onClose={() => undefined} />
    </LoggedInUserProvider>,
  );
};

afterEach(cleanup);

describe("CreateBrandAccountModal payout copy", () => {
  it("does not promise a bank copy when the bank will not be copied", () => {
    renderModal({ hasPayoutSetupToPort: true, canPortBankPayoutSetup: true, willCopyBankPayout: false });

    expect(screen.getByText("Use my existing payout setup")).toBeTruthy();
    expect(document.body.textContent).toContain("The new account will use this account's PayPal address.");
    expect(document.body.textContent).not.toContain("same legal identity and bank details");
  });

  it("promises the bank copy only when a bank will be copied", () => {
    renderModal({ hasPayoutSetupToPort: true, canPortBankPayoutSetup: true, willCopyBankPayout: true });

    expect(document.body.textContent).toContain("same legal identity and bank details");
  });

  it("keeps the blocked-country explanation when a new Connect account cannot be created", () => {
    renderModal({ hasPayoutSetupToPort: true, canPortBankPayoutSetup: false, willCopyBankPayout: false });

    expect(document.body.textContent).toContain("Bank payouts can't be set up on new accounts in your country yet");
    expect(document.body.textContent).not.toContain("same legal identity and bank details");
  });

  it("hides the checkbox when nothing portable exists", () => {
    renderModal({ hasPayoutSetupToPort: false, canPortBankPayoutSetup: false, willCopyBankPayout: false });

    expect(screen.queryByText("Use my existing payout setup")).toBeNull();
  });
});
