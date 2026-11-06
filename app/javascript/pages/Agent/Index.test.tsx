// @vitest-environment happy-dom
import { cleanup, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { UserAgentProvider } from "$app/components/UserAgent";

import AgentPage, { AgentClient, AgentPageProps } from "./Index";

const mocks = vi.hoisted(() => ({ usePage: vi.fn() }));

vi.mock("@inertiajs/react", () => ({ usePage: mocks.usePage }));

// happy-dom has no clipboard; the copy button only needs to render with the right accessible name.
vi.mock("clipboard", () => ({
  default: class FakeClipboardJS {
    on() {
      return this;
    }
    destroy() {}
  },
}));
vi.mock("$app/components/WithTooltip", () => ({
  WithTooltip: ({ children }: { children: React.ReactNode }) => children,
}));

const client = (overrides: Partial<AgentClient>): AgentClient => ({
  key: "claude",
  label: "Claude",
  capability: "Ask Claude about your sales, draft products, and check payouts.",
  connected: false,
  first_connected_at: null,
  last_used_at: null,
  pending_review: false,
  directory_url: "https://claude.ai/directory/gumroad",
  connect_label: "Add Gumroad to Claude",
  availability: "Add Gumroad from Claude’s connector directory.",
  setup: "Open Gumroad in Claude’s connector directory and connect it.",
  endpoint_url: "https://gumroad.com/claude/v1/mcp",
  ...overrides,
});

const props: AgentPageProps = {
  title: "Connect your AI to your Gumroad store",
  description: "Your own assistant can read your sales through Gumroad’s MCP server.",
  clients: [
    client({ connected: true, first_connected_at: "2026-10-02T10:00:00Z" }),
    client({
      key: "chatgpt",
      label: "ChatGPT",
      capability: "Ask ChatGPT about your sales, draft products, and check payouts.",
      directory_url: "https://chatgpt.com/plugins/plugin_x",
      connect_label: "Add Gumroad to ChatGPT",
      availability: "Add Gumroad from ChatGPT’s plugin directory.",
      setup: "Open Gumroad in ChatGPT’s plugin directory and connect it.",
      endpoint_url: "https://gumroad.com/chatgpt/v1/mcp",
    }),
    client({
      key: "muse",
      label: "Muse",
      capability: "Ask Muse about your sales, draft products, and check payouts.",
      pending_review: true,
      directory_url: null,
      connect_label: null,
      availability: "Submitted for review. The Gumroad connector is not yet available in Muse.",
      setup: "Add a remote MCP server in your client using the URL below.",
      endpoint_url: "https://gumroad.com/muse/v1/mcp",
    }),
  ],
  example_prompts: [
    { prompt: "Show my recent sales.", description: "See which products people bought and what they paid." },
    { prompt: "Draft my next product.", description: "Ask for a product name, price, and description." },
    { prompt: "Check my latest payouts.", description: "Check recent payout amounts and their status." },
  ],
  help_article_url: "https://gumroad.com/help/article/355-connect-ai-assistants-to-gumroad",
};

const renderPage = () =>
  render(
    <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
      <AgentPage />
    </UserAgentProvider>,
  );

describe("Agent/Index", () => {
  beforeEach(() => {
    mocks.usePage.mockReturnValue({ props });
  });

  afterEach(cleanup);

  it("renders the header, one card per client in order, the example prompts and the help link", () => {
    renderPage();

    expect(screen.getByRole("heading", { name: "Connect your AI to your Gumroad store" })).toBeTruthy();
    expect(
      within(screen.getByRole("region", { name: "AI clients" }))
        .getAllByRole("heading", { level: 2 })
        .map((h) => h.textContent),
    ).toEqual(["Claude", "ChatGPT", "Muse"]);
    expect(screen.getByText("“Show my recent sales.”")).toBeTruthy();
    expect(screen.getByText("“Draft my next product.”")).toBeTruthy();
    expect(screen.getByText("“Check my latest payouts.”")).toBeTruthy();
    expect(screen.getByRole("link", { name: /setup guide/u }).getAttribute("href")).toBe(props.help_article_url);
  });

  it("shows a Connected pill with the first-connect date, and Not connected otherwise", () => {
    renderPage();

    const claude = screen.getByRole("region", { name: "Claude" });
    expect(within(claude).getByText("Connected October 2, 2026")).toBeTruthy();
    const chatgpt = screen.getByRole("region", { name: "ChatGPT" });
    expect(within(chatgpt).getByText("Not connected")).toBeTruthy();
  });

  it("links the directory CTA for listed clients and disables it for the client under review", () => {
    renderPage();

    const claude = screen.getByRole("region", { name: "Claude" });
    expect(within(claude).getByRole("link", { name: "Add Gumroad to Claude" }).getAttribute("href")).toBe(
      "https://claude.ai/directory/gumroad",
    );

    const muse = screen.getByRole("region", { name: "Muse" });
    const museButton = within(muse).getByRole("button", { name: "Add Gumroad to Muse" });
    expect(museButton.hasAttribute("disabled")).toBe(true);
    expect(
      within(muse).getByRole("button", {
        name: "Add Gumroad to Muse",
        description: "Submitted for review. The Gumroad connector is not yet available in Muse.",
      }),
    ).toBe(museButton);
    expect(within(muse).queryByRole("link", { name: /Add Gumroad/u })).toBeNull();
  });

  it("shows each connector URL with a labelled copy button", () => {
    renderPage();

    const chatgpt = screen.getByRole("region", { name: "ChatGPT" });
    expect(within(chatgpt).getByText("https://gumroad.com/chatgpt/v1/mcp")).toBeTruthy();
    expect(within(chatgpt).getByRole("button", { name: "Copy ChatGPT connector URL" })).toBeTruthy();
  });
});
