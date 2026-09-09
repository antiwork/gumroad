// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
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
      user_twitter_omniauth_authorize_path: (params: Record<string, string>) =>
        `/users/auth/twitter?${new URLSearchParams(params).toString()}`,
      user_youtube_omniauth_authorize_path: () => "/users/auth/youtube",
      user_instagram_omniauth_authorize_path: () => "/users/auth/instagram",
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

  it("submits the existing read-only X connection form rather than the payout settings form", () => {
    const submit = vi.spyOn(HTMLFormElement.prototype, "submit").mockImplementation(() => undefined);
    render(<AccountStatusSection accountStatus={status} payoutsPausedBy={null} />);
    fireEvent.click(screen.getByRole("button", { name: "Connect to X" }));
    expect(submit).toHaveBeenCalledTimes(1);
    const form = document.querySelector("form");
    if (!form) throw new Error("Missing OAuth form");
    expect(form.method).toBe("post");
    expect(form.getAttribute("action")).toBe("/users/auth/twitter?state=link_twitter_account&x_auth_access_type=read");
    expect(form.querySelector<HTMLInputElement>("input[name=authenticity_token]")?.value).toBe("test-csrf");
    expect(screen.getByText(/Connecting opens your profile afterward/u)).toBeTruthy();
  });

  it("shows linked accounts and offers enabled unlinked providers using existing routes", () => {
    const submit = vi.spyOn(HTMLFormElement.prototype, "submit").mockImplementation(() => undefined);
    render(
      <AccountStatusSection
        accountStatus={{
          ...status,
          social_connections_for_review: [
            { provider: "twitter", connected: true },
            { provider: "youtube", connected: false },
            { provider: "instagram", connected: false },
            { provider: "tiktok", connected: false },
          ],
        }}
        payoutsPausedBy={null}
      />,
    );
    expect(screen.getByText("X connected")).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Connect to X" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Connect to YouTube" }));
    const youtubeForm = submit.mock.instances[0];
    if (!(youtubeForm instanceof HTMLFormElement)) throw new Error("Missing YouTube form");
    expect(youtubeForm.getAttribute("action")).toBe("/users/auth/youtube");
    fireEvent.click(screen.getByRole("button", { name: "Connect to Instagram" }));
    const instagramForm = submit.mock.instances[1];
    if (!(instagramForm instanceof HTMLFormElement)) throw new Error("Missing Instagram form");
    expect(instagramForm.getAttribute("action")).toBe("/users/auth/instagram");
    fireEvent.click(screen.getByRole("button", { name: "Connect to TikTok" }));
    const tiktokForm = submit.mock.instances[2];
    if (!(tiktokForm instanceof HTMLFormElement)) throw new Error("Missing TikTok form");
    expect(tiktokForm.getAttribute("action")).toBe("/users/auth/tiktok");
  });

  it("hides the review notice and social prompt while the system payout pause alert is showing", () => {
    render(<AccountStatusSection accountStatus={status} payoutsPausedBy="system" />);
    expect(screen.getByText(/Your payouts have been paused for a security review/u)).toBeTruthy();
    expect(screen.queryByText(status.gumroad_status ?? "")).toBeNull();
    expect(screen.queryByText("Add social connections (optional)")).toBeNull();
  });

  it("does not render a prompt or social forms when the server excludes the seller", () => {
    render(
      <AccountStatusSection
        accountStatus={{ ...status, social_connections_for_review: null }}
        payoutsPausedBy="stripe"
      />,
    );
    expect(screen.queryByText("Add social connections (optional)")).toBeNull();
    expect(document.querySelector("form")).toBeNull();
    expect(screen.getByRole("link", { name: "Complete verification" })).toBeTruthy();
  });
});
