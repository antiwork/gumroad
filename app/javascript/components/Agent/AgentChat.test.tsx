// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("$app/data/agent", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/data/agent")>();
  return {
    ...actual,
    streamAgentMessage: vi.fn(),
    fetchLatestAgentConversation: vi.fn(),
    fetchAgentTurnStatus: vi.fn(),
    executeAgentAction: vi.fn(),
  };
});

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const { AgentStreamInterruptedError, fetchAgentTurnStatus, fetchLatestAgentConversation, streamAgentMessage } =
  vi.mocked(await import("$app/data/agent"), { partial: true });
const { showAlert } = vi.mocked(await import("$app/components/server-components/Alert"));
const { AgentChat } = await import("$app/components/Agent/AgentChat");

const PERSISTED_REPLY = "Your bio currently has three lines. Want me to pull up what you have there now?";

const sendMessage = async (text: string) => {
  fireEvent.change(screen.getByLabelText("Message"), { target: { value: text } });
  fireEvent.click(screen.getByLabelText("Send"));
  // Let the in-flight turn's promise chain settle far enough to start streaming.
  await waitFor(() => expect(streamAgentMessage).toHaveBeenCalled());
};

// The client turn id streamAgentMessage was called with — recovery must query this exact id.
const sentClientTurnId = () => {
  const call = streamAgentMessage.mock.calls[streamAgentMessage.mock.calls.length - 1];
  return call?.[3];
};

const interruptedStream = () =>
  streamAgentMessage.mockImplementation(async (_messages, handlers = {}) => {
    handlers.onToken?.("Your bio currently has thr");
    await Promise.resolve();
    throw new AgentStreamInterruptedError();
  });

describe("AgentChat streamed reply reconciliation", () => {
  beforeEach(() => {
    // The mount-time "resume latest conversation" fetch: nothing to resume.
    fetchLatestAgentConversation.mockResolvedValueOnce(null);
  });

  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("replaces a partially-streamed reply with the persisted turn recovered by its id", async () => {
    interruptedStream();
    fetchAgentTurnStatus.mockResolvedValue({
      status: "persisted",
      conversation_id: "conv1",
      message: { role: "assistant", content: PERSISTED_REPLY },
    });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("what does my bio say");

    await waitFor(() => expect(screen.getByText(PERSISTED_REPLY)).toBeTruthy());
    expect(screen.queryByText("Your bio currently has thr")).toBeNull();
    expect(showAlert).not.toHaveBeenCalled();
    // Recovery asked about the exact turn that was sent — the id the stream request carried.
    expect(sentClientTurnId()).toBeTruthy();
    expect(fetchAgentTurnStatus).toHaveBeenCalledWith(sentClientTurnId());
  });

  it("adopts the recovered turn's conversation id for subsequent turns", async () => {
    interruptedStream();
    fetchAgentTurnStatus.mockResolvedValue({
      status: "persisted",
      conversation_id: "conv1",
      message: { role: "assistant", content: PERSISTED_REPLY },
    });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("what does my bio say");
    await waitFor(() => expect(screen.getByText(PERSISTED_REPLY)).toBeTruthy());

    streamAgentMessage.mockResolvedValue({
      reply: "ok",
      proposedAction: null,
      objects: [],
      suggestions: [],
      conversationId: "conv1",
    });
    await sendMessage("another question");

    await waitFor(() =>
      expect(streamAgentMessage).toHaveBeenLastCalledWith(
        expect.anything(),
        expect.anything(),
        "conv1",
        expect.any(String),
      ),
    );
  });

  it("keeps the recovered turn's proposed action confirmable", async () => {
    streamAgentMessage.mockImplementation(async (_messages, handlers = {}) => {
      handlers.onToken?.("I've prepared the bio ed");
      await Promise.resolve();
      throw new AgentStreamInterruptedError();
    });
    fetchAgentTurnStatus.mockResolvedValue({
      status: "persisted",
      conversation_id: "conv1",
      message: {
        role: "assistant",
        content: "I've prepared the bio edit for you to confirm.",
        proposed_action: { type: "api_write", params: {}, summary: "Update the bio." },
      },
    });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("update my bio");

    await waitFor(() => expect(screen.getByText("I've prepared the bio edit for you to confirm.")).toBeTruthy());
    // The proposal recovered from the just-persisted turn stays actionable — not collapsed into
    // the "stale proposal from a previous session" dismissed state hydration uses.
    expect(screen.getByText("Confirm")).toBeTruthy();
    expect(screen.getByText("Dismiss")).toBeTruthy();
  });

  it("keeps polling while the server reports the turn in progress, then recovers it", async () => {
    interruptedStream();
    fetchAgentTurnStatus
      .mockResolvedValueOnce({ status: "in_progress" })
      .mockResolvedValueOnce({ status: "in_progress" })
      .mockResolvedValueOnce({ status: "in_progress" })
      .mockResolvedValue({
        status: "persisted",
        conversation_id: "conv1",
        message: { role: "assistant", content: PERSISTED_REPLY },
      });

    vi.useFakeTimers();
    try {
      render(<AgentChat greeting="Hi" suggestions={[]} />);
      fireEvent.change(screen.getByLabelText("Message"), { target: { value: "what does my bio say" } });
      fireEvent.click(screen.getByLabelText("Send"));

      // Three in-progress polls (well past the old fixed ~13s deadline), then the persisted turn.
      await act(async () => {
        await vi.advanceTimersByTimeAsync(0);
        await vi.advanceTimersByTimeAsync(3000);
        await vi.advanceTimersByTimeAsync(3000);
        await vi.advanceTimersByTimeAsync(3000);
      });
      expect(screen.getByText(PERSISTED_REPLY)).toBeTruthy();
      expect(showAlert).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("stops immediately when the server reports the turn failed", async () => {
    interruptedStream();
    fetchAgentTurnStatus.mockResolvedValue({ status: "failed" });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("what does my bio say");

    await waitFor(() => expect(showAlert).toHaveBeenCalled());
    // One look was enough — no retry delays for a turn the server says will never persist.
    expect(fetchAgentTurnStatus).toHaveBeenCalledTimes(1);
    // The partial text that did stream is kept, exactly as before.
    expect(screen.getByText("Your bio currently has thr")).toBeTruthy();
  });

  it("gives up after consecutive unknown statuses when the turn was never persisted", async () => {
    interruptedStream();
    fetchAgentTurnStatus.mockResolvedValue({ status: "unknown" });

    vi.useFakeTimers();
    try {
      render(<AgentChat greeting="Hi" suggestions={[]} />);
      fireEvent.change(screen.getByLabelText("Message"), { target: { value: "what does my bio say" } });
      fireEvent.click(screen.getByLabelText("Send"));

      await act(async () => {
        await vi.advanceTimersByTimeAsync(0);
        await vi.advanceTimersByTimeAsync(3000);
      });

      expect(showAlert).toHaveBeenCalled();
      expect(fetchAgentTurnStatus).toHaveBeenCalledTimes(2);
      expect(screen.getByText("Your bio currently has thr")).toBeTruthy();
    } finally {
      vi.useRealTimers();
    }
  });

  it("tolerates status fetches failing (the network may still be flaky) before recovering", async () => {
    interruptedStream();
    fetchAgentTurnStatus
      .mockRejectedValueOnce(new Error("network"))
      .mockRejectedValueOnce(new Error("network"))
      .mockResolvedValue({
        status: "persisted",
        conversation_id: "conv1",
        message: { role: "assistant", content: PERSISTED_REPLY },
      });

    vi.useFakeTimers();
    try {
      render(<AgentChat greeting="Hi" suggestions={[]} />);
      fireEvent.change(screen.getByLabelText("Message"), { target: { value: "what does my bio say" } });
      fireEvent.click(screen.getByLabelText("Send"));

      await act(async () => {
        await vi.advanceTimersByTimeAsync(0);
        await vi.advanceTimersByTimeAsync(3000);
        await vi.advanceTimersByTimeAsync(3000);
      });
      expect(screen.getByText(PERSISTED_REPLY)).toBeTruthy();
      expect(showAlert).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("does not attempt recovery when the server itself reported the error", async () => {
    streamAgentMessage.mockRejectedValue(new Error("Too many requests."));

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("what does my bio say");

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Too many requests.", "error"));
    expect(fetchAgentTurnStatus).not.toHaveBeenCalled();
  });

  it("sends a fresh client turn id with every turn", async () => {
    streamAgentMessage.mockResolvedValue({
      reply: "ok",
      proposedAction: null,
      objects: [],
      suggestions: [],
      conversationId: "conv1",
    });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("first");
    const firstId = sentClientTurnId();
    await waitFor(() => expect(screen.getByText("ok")).toBeTruthy());
    await sendMessage("second");
    const secondId = sentClientTurnId();

    expect(firstId).toBeTruthy();
    expect(secondId).toBeTruthy();
    expect(firstId).not.toBe(secondId);
  });
});
