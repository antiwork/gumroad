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
    fetchCustomHtmlProposalPreview: vi.fn(),
    executeAgentAction: vi.fn(),
  };
});

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const {
  AgentStreamInterruptedError,
  executeAgentAction,
  fetchAgentTurnStatus,
  fetchCustomHtmlProposalPreview,
  fetchLatestAgentConversation,
  streamAgentMessage,
} = vi.mocked(await import("$app/data/agent"), { partial: true });
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

// The abort signal streamAgentMessage was called with. Aborting it is how the chat releases a
// connection the stream's stall timeout abandoned — allowed only once the turn's fate is known.
const sentAbortSignal = () => {
  const call = streamAgentMessage.mock.calls[streamAgentMessage.mock.calls.length - 1];
  return call?.[4];
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
        expect.any(AbortSignal),
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
    // The turn is recovered — terminal — so the abandoned connection is released.
    expect(sentAbortSignal()?.aborted).toBe(true);
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
    // "failed" is a server verdict, so any connection the stall timeout abandoned is released.
    expect(sentAbortSignal()?.aborted).toBe(true);
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
      // "unknown" is a give-up, not a server verdict — the turn may still be generating, so the
      // abandoned connection must NOT be aborted yet (that could kill a turn that would yet
      // persist).
      expect(sentAbortSignal()?.aborted).toBe(false);

      // The background watch takes over the cleanup, but "unknown" is still not a verdict — after
      // its first slow poll the connection must remain untouched.
      await act(async () => {
        await vi.advanceTimersByTimeAsync(15_000);
      });
      expect(sentAbortSignal()?.aborted).toBe(false);

      // Once the server records a verdict (the turn persisted after all), the watch releases the
      // connection — without adopting the late turn into the chat, which has moved on.
      fetchAgentTurnStatus.mockResolvedValue({
        status: "persisted",
        conversation_id: "conv1",
        message: { role: "assistant", content: PERSISTED_REPLY },
      });
      await act(async () => {
        await vi.advanceTimersByTimeAsync(15_000);
      });
      expect(sentAbortSignal()?.aborted).toBe(true);
      expect(screen.queryByText(PERSISTED_REPLY)).toBeNull();
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

  it("renders a page preview instead of raw HTML fields", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("<!doctype html><html><body><h1>New headline</h1></body></html>");

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    const iframe = await screen.findByTitle<HTMLIFrameElement>("Preview of your page after this change");
    expect(iframe.getAttribute("srcdoc")).toContain("<h1>New headline</h1>");
    // The document renders on an opaque origin, exactly like the live page embed.
    expect(iframe.getAttribute("sandbox")).toBe("allow-scripts allow-forms allow-popups");
    // The raw find/replace rows are gone — the rendered preview is the review surface.
    expect(screen.queryByText("View raw HTML")).toBeNull();
    expect(screen.queryByText("<h1>Old headline</h1>")).toBeNull();
    expect(fetchCustomHtmlProposalPreview).toHaveBeenCalledWith(
      expect.objectContaining({ params: customHtmlAction.params }),
    );
    // With the preview rendered, the proposal is confirmable.
    expect(screen.getByText("Confirm").closest("button")?.disabled).toBe(false);
  });

  it("disables Confirm until the preview has rendered", async () => {
    streamTurnWithAction(customHtmlAction);
    // A fetch that never settles: the card stays in the loading state.
    fetchCustomHtmlProposalPreview.mockReturnValue(new Promise(() => {}));

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await waitFor(() => expect(screen.getByText("Loading preview…")).toBeTruthy());
    // The seller hasn't seen the result yet, so the change can't be applied — but they can
    // still walk away from it.
    expect(screen.getByText("Confirm").closest("button")?.disabled).toBe(true);
    expect(screen.getByText("Dismiss").closest("button")?.disabled).toBe(false);
  });

  it("shows why a preview is unavailable and keeps Confirm disabled", async () => {
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
    // An invalid proposal would fail on apply too — Confirm stays off; Dismiss remains the way out.
    expect(screen.getByText("Confirm").closest("button")?.disabled).toBe(true);
    expect(screen.getByText("Dismiss").closest("button")?.disabled).toBe(false);
  });

  it("collapses an applied proposal into a compact card with the details behind Review", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("<!doctype html><html><body><h1>New headline</h1></body></html>");
    executeAgentAction.mockResolvedValue({ message: "Done.", object: null });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await screen.findByTitle("Preview of your page after this change");
    fireEvent.click(screen.getByText("Confirm"));

    // The full card (Confirm/Dismiss) collapses to a one-line applied record.
    await waitFor(() => expect(screen.getByText("Applied")).toBeTruthy());
    expect(screen.getByText("Edit your page")).toBeTruthy();
    expect(screen.queryByTitle("Preview of your page after this change")).toBeNull();
    expect(screen.queryByText("Confirm")).toBeNull();
    expect(screen.queryByText("Dismiss")).toBeNull();
    // "Review" re-shows the exact preview snapshot the seller confirmed (kept loaded, not
    // refetched — an applied edit's find-snippet no longer matches the page), and "Hide" puts
    // it away again.
    fireEvent.click(screen.getByText("Review"));
    expect(screen.getByTitle("Preview of your page after this change")).toBeTruthy();
    expect(fetchCustomHtmlProposalPreview).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByText("Hide"));
    expect(screen.queryByTitle("Preview of your page after this change")).toBeNull();
  });

  it("refetches a dismissed page proposal's preview on Review when no snapshot is loaded", async () => {
    // Hydrate a conversation whose custom-HTML proposal was already dismissed in a previous
    // session — the card mounts compact, so no preview was ever fetched in this session.
    fetchLatestAgentConversation.mockReset().mockResolvedValue({
      id: "conv1",
      title: null,
      messages: [
        { role: "user", content: "change my headline" },
        {
          role: "assistant",
          content: "Here's my proposal.",
          proposed_action: customHtmlAction,
          action_status: "dismissed",
        },
      ],
    });
    fetchCustomHtmlProposalPreview.mockResolvedValue("<!doctype html><html><body><h1>New headline</h1></body></html>");

    render(<AgentChat greeting="Hi" suggestions={[]} />);

    await waitFor(() => expect(screen.getByText("Dismissed")).toBeTruthy());
    expect(fetchCustomHtmlProposalPreview).not.toHaveBeenCalled();
    // A dismissed change never touched the page, so the server can still render exactly what the
    // seller evaluated — Review fetches it lazily.
    fireEvent.click(screen.getByText("Review"));
    await screen.findByTitle("Preview of your page after this change");
    expect(fetchCustomHtmlProposalPreview).toHaveBeenCalledTimes(1);
  });

  it("collapses a dismissed non-page proposal and reviews its field rows", async () => {
    streamTurnWithAction({
      ...customHtmlAction,
      params: { endpoint: "update_product", path_params: { id: "abc" }, params: { name: "New name" } },
      title: "Rename your product",
      fields: [{ label: "Name", value: "New name" }],
    });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("rename my product");

    await waitFor(() => expect(screen.getByText("Dismiss")).toBeTruthy());
    fireEvent.click(screen.getByText("Dismiss"));

    await waitFor(() => expect(screen.getByText("Dismissed")).toBeTruthy());
    expect(screen.queryByText("Confirm")).toBeNull();
    // The field rows are hidden in the compact card but come back under Review.
    expect(screen.queryByText("New name")).toBeNull();
    fireEvent.click(screen.getByText("Review"));
    expect(screen.getByText("New name")).toBeTruthy();
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
    // Non-page proposals never wait on a preview.
    expect(screen.getByText("Confirm").closest("button")?.disabled).toBe(false);
  });
});
