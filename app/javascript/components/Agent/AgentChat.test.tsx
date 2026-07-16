// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("$app/data/agent", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/data/agent")>();
  return {
    ...actual,
    streamAgentMessage: vi.fn(),
    fetchLatestAgentConversation: vi.fn(),
    fetchCustomHtmlProposalPreview: vi.fn(),
    executeAgentAction: vi.fn(),
  };
});

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const {
  AgentStreamInterruptedError,
  fetchCustomHtmlProposalPreview,
  fetchLatestAgentConversation,
  streamAgentMessage,
} = vi.mocked(await import("$app/data/agent"), { partial: true });
const { showAlert } = vi.mocked(await import("$app/components/server-components/Alert"));
const { AgentChat } = await import("$app/components/Agent/AgentChat");

const PERSISTED_REPLY = "Your bio currently has three lines. Want me to pull up what you have there now?";

const persistedConversation = (messages: { role: "user" | "assistant"; content: string }[]) => ({
  id: "conv1",
  title: null,
  messages,
});

const sendMessage = async (text: string) => {
  fireEvent.change(screen.getByLabelText("Message"), { target: { value: text } });
  fireEvent.click(screen.getByLabelText("Send"));
  // Let the in-flight turn's promise chain settle far enough to start streaming.
  await waitFor(() => expect(streamAgentMessage).toHaveBeenCalled());
};

describe("AgentChat streamed reply reconciliation", () => {
  beforeEach(() => {
    // The mount-time "resume latest conversation" fetch: nothing to resume.
    fetchLatestAgentConversation.mockResolvedValueOnce(null);
  });

  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("replaces a partially-streamed reply with the persisted content when the stream breaks", async () => {
    streamAgentMessage.mockImplementation(async (_messages, handlers = {}) => {
      handlers.onToken?.("Your bio currently has thr");
      await Promise.resolve();
      throw new AgentStreamInterruptedError();
    });
    fetchLatestAgentConversation.mockResolvedValue(
      persistedConversation([
        { role: "user", content: "what does my bio say" },
        { role: "assistant", content: PERSISTED_REPLY },
      ]),
    );

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("what does my bio say");

    await waitFor(() => expect(screen.getByText(PERSISTED_REPLY)).toBeTruthy());
    expect(screen.queryByText("Your bio currently has thr")).toBeNull();
    expect(showAlert).not.toHaveBeenCalled();
  });

  it("keeps the recovered turn's proposed action confirmable", async () => {
    streamAgentMessage.mockImplementation(async (_messages, handlers = {}) => {
      handlers.onToken?.("I've prepared the bio ed");
      await Promise.resolve();
      throw new AgentStreamInterruptedError();
    });
    fetchLatestAgentConversation.mockResolvedValue({
      id: "conv1",
      title: null,
      messages: [
        { role: "user", content: "update my bio" },
        {
          role: "assistant",
          content: "I've prepared the bio edit for you to confirm.",
          proposed_action: { type: "api_write", params: {}, summary: "Update the bio." },
        },
      ],
    });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("update my bio");

    await waitFor(() => expect(screen.getByText("I've prepared the bio edit for you to confirm.")).toBeTruthy());
    // The proposal recovered from the just-persisted turn stays actionable — not collapsed into
    // the "stale proposal from a previous session" dismissed state hydration uses.
    expect(screen.getByText("Confirm")).toBeTruthy();
    expect(screen.getByText("Dismiss")).toBeTruthy();
  });

  it("falls back to the error alert when the interrupted turn was never persisted", async () => {
    streamAgentMessage.mockImplementation(async (_messages, handlers = {}) => {
      handlers.onToken?.("Your bio currently has thr");
      await Promise.resolve();
      throw new AgentStreamInterruptedError();
    });
    // The stored conversation never gained this turn (the server saw the disconnect first).
    fetchLatestAgentConversation.mockResolvedValue(
      persistedConversation([
        { role: "user", content: "an older question" },
        { role: "assistant", content: "An older answer." },
      ]),
    );

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("what does my bio say");

    // Recovery retries once after a delay before giving up, so allow for it.
    await waitFor(() => expect(showAlert).toHaveBeenCalled(), { timeout: 5000 });
    // The partial text that did stream is kept, exactly as before.
    expect(screen.getByText("Your bio currently has thr")).toBeTruthy();
  }, 10_000);

  it("does not attempt recovery when the server itself reported the error", async () => {
    streamAgentMessage.mockRejectedValue(new Error("Too many requests."));

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("what does my bio say");

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Too many requests.", "error"));
    // Only the mount-time resume fetch — no reconciliation fetches for a server-reported failure.
    expect(fetchLatestAgentConversation).toHaveBeenCalledTimes(1);
  });
});

describe("AgentChat custom-html proposal cards", () => {
  const customHtmlAction = {
    type: "api_write" as const,
    params: {
      endpoint: "edit_user_custom_html",
      path_params: {},
      params: { find: "<h1>Old headline</h1>", replace: "<h1>New headline</h1>" },
    },
    summary: "Edit the custom page.",
    title: "Edit your page",
    fields: [
      { label: "Find", value: "<h1>Old headline</h1>" },
      { label: "Replace", value: "<h1>New headline</h1>" },
    ],
  };

  const streamTurnWithAction = (proposedAction: typeof customHtmlAction) => {
    streamAgentMessage.mockResolvedValue({
      reply: "I've prepared the page edit.",
      proposedAction,
      objects: [],
      suggestions: [],
      conversationId: "conv1",
    });
  };

  beforeEach(() => {
    fetchLatestAgentConversation.mockResolvedValueOnce(null);
  });

  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("renders a page preview instead of top-level raw HTML fields", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("<!doctype html><html><body><h1>New headline</h1></body></html>");

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    const iframe = await screen.findByTitle<HTMLIFrameElement>("Preview of your page after this change");
    expect(iframe.getAttribute("srcdoc")).toContain("<h1>New headline</h1>");
    // The document renders on an opaque origin, exactly like the live page embed.
    expect(iframe.getAttribute("sandbox")).toBe("allow-scripts allow-forms allow-popups");
    // The exact HTML that confirming will apply stays available, but collapsed.
    expect(screen.getByText("View raw HTML")).toBeTruthy();
    expect(fetchCustomHtmlProposalPreview).toHaveBeenCalledWith(
      expect.objectContaining({ params: customHtmlAction.params }),
    );
  });

  it("shows why a preview is unavailable instead of failing the card", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockRejectedValue(
      new Error("The snippet to replace no longer appears in the current page."),
    );

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await waitFor(() =>
      expect(
        screen.getByText("Preview unavailable: The snippet to replace no longer appears in the current page."),
      ).toBeTruthy(),
    );
    // The card is still confirmable — the preview is an aid, not a gate.
    expect(screen.getByText("Confirm")).toBeTruthy();
  });

  it("leaves non-page proposals on the plain field rows without fetching a preview", async () => {
    streamTurnWithAction({
      ...customHtmlAction,
      params: { endpoint: "update_product", path_params: { id: "abc" }, params: { name: "New name" } },
      fields: [{ label: "Name", value: "New name" }],
    });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("rename my product");

    await waitFor(() => expect(screen.getByText("New name")).toBeTruthy());
    expect(screen.queryByTitle("Preview of your page after this change")).toBeNull();
    expect(fetchCustomHtmlProposalPreview).not.toHaveBeenCalled();
  });
});
