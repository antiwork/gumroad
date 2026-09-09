// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import AccountStatusSection, { AccountStatus } from "$app/components/Settings/PaymentsPage/AccountStatusSection";

vi.mock("@inertiajs/react", () => ({ usePage: () => ({ props: { authenticity_token: "test-csrf" } }) }));

const status: AccountStatus = {
  show_section: true,
  is_suspended: false,
  suspension_reason: null,
  compliance_actions: [{ message: "Complete verification", href: "/settings/payments/remediation" }],
  needs_id_upload: false,
  gumroad_status: "Your account is under review and payouts are on hold until it's resolved.",
  social_connections_for_review: [{ provider: "twitter", connected: false }],
  stripe_rejected: false,
  stripe_rejected_balance_status: null,
  stripe_rejected_formatted_balance: null,
  stripe_rejected_payout_date: null,
};

beforeEach(() => {
  Object.assign(globalThis, {
    Routes: {
      help_center_root_path: () => "/help",
      settings_social_connections_path: () => "/settings/social_connections",
    },
  });
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe("optional review connections", () => {
  it("keeps the ordinary review and verification paths without requiring a connection", () => {
    render(<AccountStatusSection accountStatus={status} payoutsPausedBy={null} />);
    expect(screen.getByText("Add social connections (optional)")).toBeTruthy();
    expect(
      screen.getByText(/share your social account history as additional context for your account review/u),
    ).toBeTruthy();
    expect(
      screen.getByText(/does not replace identity verification or guarantee approval or a payout date/u),
    ).toBeTruthy();
    expect(screen.getByRole("link", { name: "Complete verification" }).getAttribute("href")).toBe(
      "/settings/payments/remediation",
    );
    expect(screen.getByRole("link", { name: "contact support" }).getAttribute("href")).toBe("/help");
    expect(screen.queryByRole("button", { name: "Connect to YouTube" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Connect to Instagram" })).toBeNull();
  });

  it("links to the Social connections settings page instead of starting OAuth on Payments", () => {
    render(<AccountStatusSection accountStatus={status} payoutsPausedBy={null} />);
    expect(screen.getByText("X available to connect")).toBeTruthy();
    expect(screen.getByRole("link", { name: "Manage social connections" }).getAttribute("href")).toBe(
      "/settings/social_connections",
    );
    expect(screen.queryByRole("button", { name: "Connect to X" })).toBeNull();
  });

  it("shows linked accounts and points remaining providers at Settings", () => {
    render(
      <AccountStatusSection
        accountStatus={{
          ...status,
          social_connections_for_review: [
            { provider: "twitter", connected: true },
            { provider: "youtube", connected: false },
            { provider: "instagram", connected: false },
          ],
        }}
        payoutsPausedBy={null}
      />,
    );
    expect(screen.getByText("X connected")).toBeTruthy();
    expect(screen.getByText("YouTube available to connect")).toBeTruthy();
    expect(screen.getByText("Instagram available to connect")).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Connect to X" })).toBeNull();
    expect(screen.getByRole("link", { name: "Manage social connections" }).getAttribute("href")).toBe(
      "/settings/social_connections",
    );
  });

  it("hides the review notice and social prompt while the system payout pause alert is showing", () => {
    render(<AccountStatusSection accountStatus={status} payoutsPausedBy="system" />);
    expect(screen.getByText(/Your payouts have been paused for a security review/u)).toBeTruthy();
    expect(screen.queryByText(status.gumroad_status ?? "")).toBeNull();
    expect(screen.queryByText("Add social connections (optional)")).toBeNull();
  });

  it("does not render a prompt when the server excludes the seller", () => {
    render(
      <AccountStatusSection
        accountStatus={{ ...status, social_connections_for_review: null }}
        payoutsPausedBy="stripe"
      />,
    );
    expect(screen.queryByText("Add social connections (optional)")).toBeNull();
    expect(screen.queryByRole("link", { name: "Manage social connections" })).toBeNull();
    expect(screen.getByRole("link", { name: "Complete verification" })).toBeTruthy();
  });
});
