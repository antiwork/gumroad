// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { type Workflow } from "$app/types/workflow";

import { LoggedInUserProvider, type LoggedInUser } from "$app/components/LoggedInUser";
import WorkflowList from "$app/components/WorkflowsPage/WorkflowList";

vi.mock("@inertiajs/react", () => ({
  Link: ({ href, children, ...rest }: { href?: string; children?: React.ReactNode }) => (
    <a href={href} {...rest}>
      {children}
    </a>
  ),
  router: { delete: vi.fn(), reload: vi.fn() },
  usePage: () => ({ props: {}, url: "/workflows", component: "Workflows/Index", version: null }),
}));

vi.hoisted(() => {
  const url = (path: string) => () => path;
  Object.assign(globalThis, {
    Routes: {
      new_workflow_path: url("/workflows/new"),
      workflow_path: (id: string) => `/workflows/${id}`,
      edit_workflow_path: (id: string) => `/workflows/${id}/edit`,
      workflow_emails_path: (id: string) => `/workflows/${id}/emails`,
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
  canPortBankPayoutSetup: false,
  willCopyBankPayout: false,
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
    workflow: { create: true },
    utm_link: { index: false },
    community: { index: false },
    churn: { show: false },
    page: { index: false, create: false },
    user: { view_store_agent: false, use_store_agent: false },
  },
  promotedNavItems: [],
  lazyLoadOffscreenDiscoverImages: false,
};

const workflow = (name: string, externalId: string): Workflow => ({
  external_id: externalId,
  name,
  workflow_type: "seller",
  workflow_trigger: null,
  published: false,
  first_published_at: null,
  send_to_past_customers: false,
  installments: [],
});

const workflows = [workflow("Weekly launch", "wf_1"), workflow("Abandoned checkout", "wf_2")];

const openSearch = () => {
  fireEvent.click(screen.getByRole("button", { name: "Toggle Search" }));
  const input = screen.getByRole("textbox");
  if (!(input instanceof HTMLInputElement)) throw new Error("expected the search field to be an <input>");
  return input;
};

const renderList = () =>
  render(
    <LoggedInUserProvider value={loggedInUser}>
      <WorkflowList workflows={workflows} />
    </LoggedInUserProvider>,
  );

describe("WorkflowList search", () => {
  it("filters workflows by name as the seller types", () => {
    renderList();
    expect(screen.getByText("Weekly launch")).toBeTruthy();
    expect(screen.getByText("Abandoned checkout")).toBeTruthy();

    fireEvent.change(openSearch(), { target: { value: "launch" } });

    expect(screen.getByText("Weekly launch")).toBeTruthy();
    expect(screen.queryByText("Abandoned checkout")).toBeNull();
  });

  it("matches regardless of case", () => {
    renderList();

    fireEvent.change(openSearch(), { target: { value: "ABANDONED" } });

    expect(screen.getByText("Abandoned checkout")).toBeTruthy();
    expect(screen.queryByText("Weekly launch")).toBeNull();
  });

  it("shows a no-results message instead of the empty-list placeholder", () => {
    renderList();

    fireEvent.change(openSearch(), { target: { value: "nothing like this" } });

    expect(screen.getByText('No workflows found for "nothing like this"')).toBeTruthy();
    expect(screen.queryByText("Automate emails with ease.")).toBeNull();
  });

  it("only offers search once the seller has workflows", () => {
    render(
      <LoggedInUserProvider value={loggedInUser}>
        <WorkflowList workflows={[]} />
      </LoggedInUserProvider>,
    );

    expect(screen.queryByRole("button", { name: "Toggle Search" })).toBeNull();
    expect(screen.getByText("Automate emails with ease.")).toBeTruthy();

    cleanup();
    renderList();
    expect(screen.getByRole("button", { name: "Toggle Search" })).toBeTruthy();
  });
});
