// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { MarketingCartRecovery } from "$app/data/marketing_cart_recovery";
import { ResponseError } from "$app/utils/request";

import { CartRecoveryCard } from "$app/components/ProductEdit/ShareTab/CartRecoveryCard";
import { showAlert } from "$app/components/server-components/Alert";

const fetchCartRecovery = vi.fn<(id: string) => Promise<MarketingCartRecovery>>();
const updateCartRecovery = vi.fn<(id: string, enabled: boolean) => Promise<MarketingCartRecovery>>();
vi.mock("$app/data/marketing_cart_recovery", () => ({
  fetchCartRecovery: (id: string) => fetchCartRecovery(id),
  updateCartRecovery: (id: string, enabled: boolean) => updateCartRecovery(id, enabled),
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const workflow = { name: "Cart reminder", url: "/workflows/wf1/emails", scope: "Field Notes Workbook", enabled: true };
const state = (overrides: Partial<MarketingCartRecovery> = {}): MarketingCartRecovery => ({
  available: true,
  blocked_reason: null,
  enabled: false,
  can_toggle: true,
  subject: "You left something in your cart",
  message: "<p>Complete your checkout.</p>",
  delay_hours: 24,
  workflows: [],
  ...overrides,
});

const renderCard = async (recovery: MarketingCartRecovery) => {
  fetchCartRecovery.mockResolvedValue(recovery);
  render(<CartRecoveryCard productPermalink="abc" />);
  await screen.findByRole("switch", { name: "Abandoned cart email" });
};

const toggle = () => screen.getByRole("switch", { name: "Abandoned cart email" });

describe("CartRecoveryCard", () => {
  beforeEach(() => vi.resetAllMocks());
  afterEach(() => cleanup());

  it("previews the actual email before the seller enables it", async () => {
    await renderCard(state({ subject: "Your workbook is waiting", message: "<p>Return to your workbook.</p>" }));

    fireEvent.click(screen.getByText("Preview email"));
    expect(screen.getByText("Your workbook is waiting")).toBeDefined();
    expect(screen.getByTitle("Email preview").getAttribute("srcdoc")).toContain("Return to your workbook.");
    expect(toggle()).toHaveProperty("checked", false);
    expect(screen.queryByRole("link", { name: "Edit email" })).toBeNull();
  });

  it("shows progress until the server confirms enabling", async () => {
    await renderCard(state());
    let finish!: (value: MarketingCartRecovery) => void;
    updateCartRecovery.mockReturnValue(
      new Promise((resolve) => {
        finish = resolve;
      }),
    );
    fireEvent.click(toggle());

    expect(screen.getByRole("status").textContent).toBe("Turning on…");
    expect(toggle()).toHaveProperty("disabled", true);
    finish(state({ enabled: true, workflows: [workflow] }));
    await waitFor(() => expect(toggle()).toHaveProperty("checked", true));
    expect(screen.getByRole("link", { name: "Edit email" }).getAttribute("href")).toBe(workflow.url);
  });

  it("allows pausing an enabled workflow after eligibility is lost", async () => {
    await renderCard(
      state({
        available: false,
        enabled: true,
        blocked_reason: "Available after your first payout.",
        workflows: [workflow],
      }),
    );
    updateCartRecovery.mockResolvedValue(state({ available: false, enabled: false, workflows: [workflow] }));

    expect(toggle()).toHaveProperty("disabled", false);
    expect(screen.getByRole("link", { name: "Edit email" })).toBeDefined();
    fireEvent.click(toggle());
    await waitFor(() => expect(updateCartRecovery).toHaveBeenCalledWith("abc", false));
    await waitFor(() => expect(toggle()).toHaveProperty("checked", false));
    expect(toggle()).toHaveProperty("disabled", true);
  });

  it("keeps the confirmed state when an update fails", async () => {
    await renderCard(state());
    updateCartRecovery.mockRejectedValue(new ResponseError("Try again later."));
    fireEvent.click(toggle());

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Try again later.", "error"));
    expect(toggle()).toHaveProperty("checked", false);
    expect(toggle()).toHaveProperty("disabled", false);
  });

  it("shows shared scope without a product switch", async () => {
    fetchCartRecovery.mockResolvedValue(
      state({ can_toggle: false, workflows: [{ ...workflow, scope: "Workbook and Calendar" }] }),
    );
    render(<CartRecoveryCard productPermalink="abc" />);

    await screen.findByRole("link", { name: workflow.name });
    expect(screen.getByText("On · Workbook and Calendar")).toBeDefined();
    expect(screen.queryByRole("switch")).toBeNull();
  });

  it("retries loading after a request fails", async () => {
    fetchCartRecovery.mockRejectedValueOnce(new ResponseError()).mockResolvedValueOnce(state());
    render(<CartRecoveryCard productPermalink="abc" />);

    fireEvent.click(await screen.findByRole("button", { name: "Try again" }));
    await screen.findByRole("switch");
    expect(fetchCartRecovery).toHaveBeenCalledTimes(2);
  });

  it("ignores a response for a previous product", async () => {
    let finish!: (value: MarketingCartRecovery) => void;
    fetchCartRecovery
      .mockReturnValueOnce(
        new Promise((resolve) => {
          finish = resolve;
        }),
      )
      .mockResolvedValueOnce(state({ subject: "Current product" }));
    const { rerender } = render(<CartRecoveryCard productPermalink="old" />);
    rerender(<CartRecoveryCard productPermalink="new" />);
    await screen.findByRole("switch");
    finish(state({ subject: "Old product" }));
    await waitFor(() => expect(screen.queryByText("Old product")).toBeNull());
    expect(screen.getByText("Current product")).toBeDefined();
  });
});
