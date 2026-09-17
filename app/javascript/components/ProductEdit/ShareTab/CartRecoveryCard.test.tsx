// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { MarketingCartRecovery } from "$app/data/marketing_cart_recovery";
import { ResponseError } from "$app/utils/request";

import { CartRecoveryCard } from "$app/components/ProductEdit/ShareTab/CartRecoveryCard";

const fetchCartRecovery = vi.fn<(id: string) => Promise<MarketingCartRecovery>>();
const updateCartRecovery = vi.fn<(id: string, enabled: boolean) => Promise<MarketingCartRecovery>>();
vi.mock("$app/data/marketing_cart_recovery", () => ({
  fetchCartRecovery: (id: string) => fetchCartRecovery(id),
  updateCartRecovery: (id: string, enabled: boolean) => updateCartRecovery(id, enabled),
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const state = (overrides: Partial<MarketingCartRecovery> = {}): MarketingCartRecovery => ({
  available: true,
  blocked_reason: null,
  enabled: false,
  account_wide: false,
  subject: "You left something in your cart",
  delay_hours: 24,
  workflow_url: null,
  ...overrides,
});

const renderCard = async (recovery: MarketingCartRecovery) => {
  fetchCartRecovery.mockResolvedValue(recovery);
  render(<CartRecoveryCard productPermalink="abc" />);
  await screen.findByRole("heading", { name: "Abandoned cart email" });
};

describe("CartRecoveryCard", () => {
  beforeEach(() => vi.clearAllMocks());
  afterEach(() => cleanup());

  it("shows what the email says and when it goes out before the seller enables it", async () => {
    await renderCard(state());

    expect(screen.getByText(/Anyone who leaves this product in their cart gets/u).textContent).toContain(
      "“You left something in your cart” 24 hours later",
    );
    expect(screen.queryByText("Off")).toBeNull();
    expect(screen.queryByText("On")).toBeNull();
    expect(screen.getByRole("switch", { name: "Abandoned cart email" })).toHaveProperty("checked", false);
    expect(screen.queryByRole("link", { name: "Open in Workflows" })).toBeNull();
  });

  it("enables cart recovery and then shows the workflow to edit", async () => {
    await renderCard(state());
    updateCartRecovery.mockResolvedValue(state({ enabled: true, workflow_url: "/workflows/wf1/emails" }));

    fireEvent.click(screen.getByRole("switch", { name: "Abandoned cart email" }));

    await waitFor(() => expect(updateCartRecovery).toHaveBeenCalledWith("abc", true));
    await waitFor(() =>
      expect(screen.getByRole("switch", { name: "Abandoned cart email" })).toHaveProperty("checked", true),
    );
    expect(screen.queryByText(/Nothing is sent until/u)).toBeNull();
    expect(screen.getByRole("link", { name: "Open in Workflows" })).toHaveProperty(
      "href",
      expect.stringContaining("/workflows/wf1/emails"),
    );
  });

  it("pauses cart recovery when the seller turns it back off", async () => {
    await renderCard(state({ enabled: true, workflow_url: "/workflows/wf1/emails" }));
    updateCartRecovery.mockResolvedValue(state({ enabled: false, workflow_url: "/workflows/wf1/emails" }));

    fireEvent.click(screen.getByRole("switch", { name: "Abandoned cart email" }));

    await waitFor(() => expect(updateCartRecovery).toHaveBeenCalledWith("abc", false));
    await waitFor(() =>
      expect(screen.getByRole("switch", { name: "Abandoned cart email" })).toHaveProperty("checked", false),
    );
    // The workflow is paused, not deleted, so it is still there to edit.
    expect(screen.getByRole("link", { name: "Open in Workflows" })).toBeDefined();
  });

  it("shows the reason and a disabled toggle for a seller who cannot use it yet", async () => {
    await renderCard(
      state({ available: false, blocked_reason: "Cart reminders turn on once you've received your first payout." }),
    );

    expect(screen.getByRole("status").tagName).toBe("P");
    expect(screen.getByRole("status").textContent).toBe(
      "Cart reminders turn on once you've received your first payout.",
    );
    expect(screen.getByRole("switch", { name: "Abandoned cart email" })).toHaveProperty("disabled", true);
  });

  it("renders nothing when the endpoint refuses the seller", async () => {
    fetchCartRecovery.mockRejectedValue(new ResponseError());
    const { container } = render(<CartRecoveryCard productPermalink="abc" />);
    await waitFor(() => expect(fetchCartRecovery).toHaveBeenCalled());

    expect(container.textContent).toBe("");
  });
});
