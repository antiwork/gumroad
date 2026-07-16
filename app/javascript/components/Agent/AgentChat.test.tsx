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
    executeAgentAction: vi.fn(),
  };
});

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const { AgentStreamInterruptedError, fetchLatestAgentConversation, streamAgentMessage } = vi.mocked(
  await import("$app/data/agent"),
  { partial: true },
);
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

  it("does not adopt another tab's ongoing conversation when recovering a fresh chat", async () => {
    streamAgentMessage.mockImplementation(async (_messages, handlers = {}) => {
      handlers.onToken?.("Your bio currently has thr");
      await Promise.resolve();
      throw new AgentStreamInterruptedError();
    });
    // The seller's latest conversation is another tab's longer chat that happens to end with the
    // same prompt text. A fresh chat's interrupted turn would have been stored as a brand-new
    // two-message conversation, so this must not be adopted.
    fetchLatestAgentConversation.mockResolvedValue({
      id: "other-tab-conv",
      title: null,
      messages: [
        { role: "user" as const, content: "an earlier question" },
        { role: "assistant" as const, content: "An earlier answer." },
        { role: "user" as const, content: "what does my bio say" },
        { role: "assistant" as const, content: PERSISTED_REPLY },
      ],
    });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("what does my bio say");

    // Recovery declines the other tab's conversation and falls through to the error handling.
    await waitFor(() => expect(showAlert).toHaveBeenCalled(), { timeout: 5000 });
    expect(screen.queryByText(PERSISTED_REPLY)).toBeNull();
    // The next turn must not carry the other tab's conversation id.
    streamAgentMessage.mockResolvedValue({
      reply: "ok",
      proposedAction: null,
      objects: [],
      suggestions: [],
      conversationId: null,
    });
    await sendMessage("another question");
    await waitFor(() =>
      expect(streamAgentMessage).toHaveBeenLastCalledWith(expect.anything(), expect.anything(), null),
    );
  }, 10_000);

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

describe("AgentChat fresh-chat recovery guards", () => {
  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("does not adopt the pre-existing latest conversation even when its tail matches the sent text", async () => {
    // The seller sends before the mount-time fetch resolves, so hydration is skipped and the chat
    // stays fresh (no conversation id) — but the fetch still tells us which conversation already
    // existed. When recovery later sees that same conversation (another tab appended the identical
    // prompt to it), it must not be mistaken for our just-persisted first turn.
    let resolveMountFetch: (value: ReturnType<typeof persistedConversation>) => void = () => {};
    const olderConversation = {
      id: "conv-old",
      title: null,
      messages: [
        { role: "user" as const, content: "what does my bio say" },
        { role: "assistant" as const, content: "The other tab's reply." },
      ],
    };
    fetchLatestAgentConversation.mockReturnValueOnce(
      new Promise((resolve) => {
        resolveMountFetch = resolve;
      }),
    );
    streamAgentMessage.mockImplementation(async (_messages, handlers = {}) => {
      handlers.onToken?.("Your bio currently has thr");
      resolveMountFetch(olderConversation);
      await Promise.resolve();
      throw new AgentStreamInterruptedError();
    });
    fetchLatestAgentConversation.mockResolvedValue(olderConversation);

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("what does my bio say");

    await waitFor(() => expect(showAlert).toHaveBeenCalled(), { timeout: 10_000 });
    expect(screen.queryByText("The other tab's reply.")).toBeNull();
  }, 15_000);

  it("skips fresh-chat recovery entirely while the pre-existing latest conversation is unknown", async () => {
    // The mount-time fetch never resolves, so we can't tell a just-persisted first turn apart from
    // a conversation that existed all along — recovery must decline rather than guess.
    fetchLatestAgentConversation.mockReturnValueOnce(new Promise(() => {}));
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

    await waitFor(() => expect(showAlert).toHaveBeenCalled(), { timeout: 10_000 });
    expect(screen.queryByText(PERSISTED_REPLY)).toBeNull();
  }, 15_000);
});
