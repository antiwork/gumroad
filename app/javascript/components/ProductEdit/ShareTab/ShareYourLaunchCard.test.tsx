// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { MarketingAction, MarketingChannel } from "$app/data/marketing_actions";

import { ShareYourLaunchCard } from "$app/components/ProductEdit/ShareTab/ShareYourLaunchCard";

const fetchMarketingRecommendations = vi.fn<(id: string) => Promise<MarketingChannel[]>>();
const approveMarketingAction = vi.fn<(id: string, actionId: string, copy?: string) => Promise<MarketingAction>>();
const executeMarketingAction =
  vi.fn<
    (id: string, actionId: string) => Promise<{ action: MarketingAction; intent_url: string; connect_path: string }>
  >();
const cancelMarketingAction = vi.fn<(id: string, actionId: string) => Promise<MarketingAction>>();
vi.mock("$app/data/marketing_actions", () => ({
  fetchMarketingRecommendations: (id: string) => fetchMarketingRecommendations(id),
  approveMarketingAction: (id: string, actionId: string, copy?: string) => approveMarketingAction(id, actionId, copy),
  executeMarketingAction: (id: string, actionId: string) => executeMarketingAction(id, actionId),
  cancelMarketingAction: (id: string, actionId: string) => cancelMarketingAction(id, actionId),
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const action = (overrides: Partial<MarketingAction> = {}): MarketingAction => ({
  id: "act1",
  channel: "x",
  status: "recommended",
  copy: "Gumstein Letters: ten years from the Andes.",
  post_text: "Gumstein Letters: ten years from the Andes.\n\nhttps://gum.co/u/abcd1234",
  link_url: "https://gum.co/u/abcd1234",
  external_url: null,
  error_code: null,
  approved_at: null,
  posted_at: null,
  ...overrides,
});

const comingSoon: MarketingChannel[] = [
  { channel: "instagram", label: "Instagram", live: false },
  { channel: "youtube", label: "YouTube", live: false },
  { channel: "tiktok", label: "TikTok", live: false },
];

const xChannel = (overrides: Partial<MarketingChannel> = {}): MarketingChannel => ({
  channel: "x",
  label: "X",
  live: true,
  connected: true,
  handle: "edgar",
  connect_path: "/settings/social_connections",
  intent_url: "https://twitter.com/intent/tweet?text=hi",
  action: action(),
  ...overrides,
});

const renderCard = async (channels: MarketingChannel[]) => {
  fetchMarketingRecommendations.mockResolvedValue(channels);
  render(<ShareYourLaunchCard productPermalink="abc" />);
  await screen.findByText("Share your launch");
};

describe("ShareYourLaunchCard", () => {
  beforeEach(() => vi.clearAllMocks());
  afterEach(() => cleanup());

  it("shows only available posting channels", async () => {
    await renderCard([xChannel(), ...comingSoon]);

    expect(screen.getByText("Posting as @edgar")).toBeDefined();
    expect(screen.getByRole("button", { name: "Post on X" })).not.toHaveProperty("disabled", true);
    expect(screen.queryByText("Coming soon")).toBeNull();
    for (const label of ["Instagram", "YouTube", "TikTok"]) {
      expect(screen.queryByRole("button", { name: `Post on ${label}` })).toBeNull();
    }
  });

  it("offers manual sharing and a separate account connection when X is disconnected", async () => {
    await renderCard([xChannel({ connected: false, handle: null }), ...comingSoon]);

    expect(screen.getByRole("link", { name: "Connect X for direct posting" })).toHaveProperty(
      "href",
      expect.stringContaining("/settings/social_connections"),
    );
    expect(screen.getByRole("link", { name: "Continue on X" })).toBeDefined();
    expect(screen.queryByRole("button", { name: "Post on X" })).toBeNull();
    fireEvent.change(screen.getByLabelText("Post text"), { target: { value: "Edited launch text" } });
    expect(screen.getByRole("link", { name: "Continue on X" }).getAttribute("href")).toContain(
      "Edited%20launch%20text",
    );
  });

  it("asks for explicit confirmation showing the exact text, account and link, then approves and executes", async () => {
    await renderCard([xChannel()]);
    approveMarketingAction.mockResolvedValue(action({ status: "approved", copy: "Edited copy" }));
    executeMarketingAction.mockResolvedValue({
      action: action({ status: "posted", external_url: "https://x.com/edgar/status/1" }),
      intent_url: "https://twitter.com/intent/tweet?text=hi",
      connect_path: "/settings/social_connections",
    });

    fireEvent.change(screen.getByLabelText("Post text"), { target: { value: "Edited copy" } });
    fireEvent.click(screen.getByRole("button", { name: "Post on X" }));

    expect(executeMarketingAction).not.toHaveBeenCalled();
    const dialog = await screen.findByRole("dialog");
    expect(dialog.textContent).toContain("@edgar");
    expect(dialog.textContent).toContain("Edited copy");
    expect(dialog.textContent).toContain("https://gum.co/u/abcd1234");

    act(() => {
      fireEvent.click(screen.getByRole("button", { name: "Post now" }));
    });

    await waitFor(() => expect(executeMarketingAction).toHaveBeenCalledWith("abc", "act1"));
    expect(approveMarketingAction).toHaveBeenCalledWith("abc", "act1", "Edited copy");
    expect(screen.getByRole("link", { name: "View post on X" })).toHaveProperty("href", "https://x.com/edgar/status/1");
    expect(screen.queryByRole("button", { name: "Post on X" })).toBeNull();
  });

  it("keeps the intent share and Reconnect X on a saved action that cannot write", async () => {
    await renderCard([xChannel({ action: action({ status: "approved", error_code: "x_write_permission_missing" }) })]);

    expect(screen.getByText(/only allows reading/u)).toBeDefined();
    expect(screen.getByRole("link", { name: "Share on X" })).toBeDefined();
    expect(screen.getByRole("link", { name: "Reconnect X" })).toBeDefined();
    expect(screen.getByRole("button", { name: "Post on X" })).toBeDefined();
  });

  it("tells the seller to check X when a post's result is unknown", async () => {
    await renderCard([xChannel({ action: action({ status: "failed", error_code: "x_post_result_unknown" }) })]);

    expect(screen.getByText(/couldn't confirm whether this post went through/u)).toBeDefined();
    expect(screen.getByRole("link", { name: "Share on X" })).toBeDefined();
    expect(screen.queryByRole("button", { name: "Post on X" })).toBeNull();
  });

  it("keeps one composer and restores each destination draft", async () => {
    const instagram = xChannel({
      channel: "instagram",
      label: "Instagram",
      handle: "fieldnotes",
      action: action({ id: "ig1", channel: "instagram", copy: "Instagram draft" }),
    });
    await renderCard([xChannel(), instagram, ...comingSoon.slice(1)]);
    fireEvent.change(screen.getByLabelText("Post text"), { target: { value: "Edited X draft" } });
    fireEvent.click(screen.getByRole("radio", { name: "Instagram" }));
    expect(screen.getAllByRole("textbox")).toHaveLength(1);
    expect(screen.getByLabelText("Post text")).toHaveProperty("value", "Instagram draft");
    fireEvent.change(screen.getByLabelText("Post text"), { target: { value: "Edited Instagram draft" } });
    fireEvent.click(screen.getByRole("radio", { name: "X" }));
    expect(screen.getByLabelText("Post text")).toHaveProperty("value", "Edited X draft");
    fireEvent.click(screen.getByRole("radio", { name: "Instagram" }));
    expect(screen.getByLabelText("Post text")).toHaveProperty("value", "Edited Instagram draft");
    expect(screen.getByText("Posting as @fieldnotes")).toBeDefined();
    expect(screen.queryByRole("radio", { name: "YouTube" })).toBeNull();
  });

  it("confirms and posts only the selected destination draft", async () => {
    const instagramAction = action({ id: "ig1", channel: "instagram", copy: "Instagram draft" });
    await renderCard([xChannel(), xChannel({ channel: "instagram", label: "Instagram", action: instagramAction })]);
    fireEvent.click(screen.getByRole("radio", { name: "Instagram" }));
    fireEvent.change(screen.getByLabelText("Post text"), { target: { value: "Edited Instagram draft" } });
    let finishPosting: ((value: Awaited<ReturnType<typeof executeMarketingAction>>) => void) | undefined;
    approveMarketingAction.mockResolvedValue({
      ...instagramAction,
      status: "approved",
      copy: "Edited Instagram draft",
    });
    executeMarketingAction.mockReturnValue(
      new Promise((resolve) => {
        finishPosting = resolve;
      }),
    );
    fireEvent.click(screen.getByRole("button", { name: "Post on Instagram" }));
    expect(screen.getByRole("dialog").textContent).toContain("Post on Instagram?");
    expect(executeMarketingAction).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Post now" }));
    await waitFor(() => expect(executeMarketingAction).toHaveBeenCalledWith("abc", "ig1"));
    expect(approveMarketingAction).toHaveBeenCalledWith("abc", "ig1", "Edited Instagram draft");
    expect(screen.getByRole("radio", { name: "X", hidden: true })).toHaveProperty("disabled", true);
    act(() =>
      finishPosting?.({
        action: { ...instagramAction, status: "posted", external_url: "https://instagram.com/p/example" },
        intent_url: "",
        connect_path: "",
      }),
    );
    expect(await screen.findByRole("link", { name: "View post on Instagram" })).toBeDefined();
    fireEvent.click(screen.getByRole("radio", { name: "X" }));
    expect(screen.getByRole("button", { name: "Post on X" })).toBeDefined();
  });

  it("does not restore another product's channels or drafts after a late response", async () => {
    let finishFirst: ((channels: MarketingChannel[]) => void) | undefined;
    fetchMarketingRecommendations.mockReturnValueOnce(
      new Promise((resolve) => {
        finishFirst = resolve;
      }),
    );
    const { rerender } = render(<ShareYourLaunchCard productPermalink="first" />);
    fetchMarketingRecommendations.mockResolvedValueOnce([xChannel({ action: action({ copy: "Second product" }) })]);
    rerender(<ShareYourLaunchCard productPermalink="second" />);
    await screen.findByDisplayValue("Second product");
    await act(() => Promise.resolve(finishFirst?.([xChannel()])));
    expect(screen.getByLabelText("Post text")).toHaveProperty("value", "Second product");
    expect(screen.queryByRole("radio")).toBeNull();
  });

  it("renders nothing when the endpoint returns no channels", async () => {
    fetchMarketingRecommendations.mockResolvedValue([]);
    const { container } = render(<ShareYourLaunchCard productPermalink="abc" />);
    await waitFor(() => expect(fetchMarketingRecommendations).toHaveBeenCalled());
    expect(container.textContent).toBe("");
  });
});
