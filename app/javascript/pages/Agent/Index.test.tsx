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
  connected: false,
  first_connected_at: null,
  last_used_at: null,
  pending_review: false,
  directory_url: "https://claude.ai/directory/gumroad",
  connect_label: "Add Gumroad to Claude",
  availability: "Add Gumroad from Claude’s connector directory.",
  setup: "Open Settings > Connectors in Claude, choose Add custom connector, and enter the URL below.",
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
      directory_url: "https://chatgpt.com/plugins/plugin_x",
      connect_label: "Add Gumroad to ChatGPT",
      availability: "Add Gumroad from ChatGPT’s plugin directory.",
      setup: "If you cannot add plugins, ask your workspace administrator.",
      endpoint_url: "https://gumroad.com/chatgpt/v1/mcp",
    }),
    client({
      key: "muse",
      label: "Muse",
      pending_review: true,
      directory_url: null,
      connect_label: null,
      availability: "Submitted for review. The Gumroad connector is not yet available in Muse.",
      setup: null,
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

  it("links the directory CTA only for a listed client that is not connected yet", () => {
    renderPage();

    const chatgpt = screen.getByRole("region", { name: "ChatGPT" });
    expect(within(chatgpt).getByRole("link", { name: "Add Gumroad to ChatGPT" }).getAttribute("href")).toBe(
      "https://chatgpt.com/plugins/plugin_x",
    );
    expect(within(chatgpt).getByText("Add Gumroad from ChatGPT’s plugin directory.")).toBeTruthy();

    const claude = screen.getByRole("region", { name: "Claude" });
    expect(within(claude).queryByRole("link", { name: /Add Gumroad/u })).toBeNull();
    expect(within(claude).queryByText("Add Gumroad from Claude’s connector directory.")).toBeNull();
    expect(within(claude).getByRole("heading", { name: "Setup" })).toBeTruthy();
    expect(within(claude).getByText("https://gumroad.com/claude/v1/mcp")).toBeTruthy();
  });

  it("disables the add button for the client under review and offers no setup path for it", () => {
    renderPage();

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
    expect(within(muse).queryByRole("heading", { name: "Setup" })).toBeNull();
    expect(within(muse).queryByText("https://gumroad.com/muse/v1/mcp")).toBeNull();
    expect(within(muse).queryByRole("button", { name: "Copy Muse connector URL" })).toBeNull();
  });

  it("keeps the review note but drops the disabled button once the client under review is connected", () => {
    mocks.usePage.mockReturnValue({
      props: {
        ...props,
        clients: props.clients.map((c) =>
          c.key === "muse" ? { ...c, connected: true, first_connected_at: "2026-10-05T10:00:00Z" } : c,
        ),
      },
    });
    renderPage();

    const muse = screen.getByRole("region", { name: "Muse" });
    expect(within(muse).getByText("Connected October 5, 2026")).toBeTruthy();
    expect(within(muse).queryByRole("button", { name: "Add Gumroad to Muse" })).toBeNull();
    expect(
      within(muse).getByText("Submitted for review. The Gumroad connector is not yet available in Muse."),
    ).toBeTruthy();
  });

  it("shows each connector URL with a labelled copy button", () => {
    renderPage();

    const chatgpt = screen.getByRole("region", { name: "ChatGPT" });
    expect(within(chatgpt).getByText("https://gumroad.com/chatgpt/v1/mcp")).toBeTruthy();
    expect(within(chatgpt).getByRole("button", { name: "Copy ChatGPT connector URL" })).toBeTruthy();
  });
});
