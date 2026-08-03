// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { RateLimitError, ResponseError } from "$app/utils/request";

vi.mock("$app/data/agent", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/data/agent")>();
  return {
    ...actual,
    streamAgentMessage: vi.fn(),
    fetchLatestAgentConversation: vi.fn(),
    fetchAgentActionStatus: vi.fn(),
    fetchAgentTurnStatus: vi.fn(),
    fetchCustomHtmlProposalPreview: vi.fn(),
    executeAgentAction: vi.fn(),
  };
});

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const {
  AgentActionError,
  AgentStreamInterruptedError,
  executeAgentAction,
  fetchAgentActionStatus,
  fetchAgentTurnStatus,
  fetchCustomHtmlProposalPreview,
  fetchLatestAgentConversation,
  streamAgentMessage,
} = vi.mocked(await import("$app/data/agent"), { partial: true });
const { showAlert } = vi.mocked(await import("$app/components/server-components/Alert"));
const { AgentChat } = await import("$app/components/Agent/AgentChat");

const PERSISTED_REPLY = "Your bio currently has three lines. Want me to pull up what you have there now?";
const ACTION_STATUS_RECONCILIATION_INTERVAL_MS = 500;
const ACTION_STATUS_RACK_HORIZON_MS = 120_000;
const ACTION_STATUS_FINAL_POLL_DELAY_MS = 7500;
const ACTION_STATUS_RECONCILIATION_DEADLINE_MS = 130_000;

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
      proposalMessageId: null,
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
        proposal_message_id: "message1",
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

      await act(async () => {
        await vi.advanceTimersByTimeAsync(0);
      });
      // The missing frame may have been the reset that removes a false staging claim. Hide partial
      // text immediately rather than leaving it visible through a long status-polling wait.
      expect(screen.queryByText("Your bio currently has thr")).toBeNull();
      expect(screen.getByRole("status", { name: "Working on it" })).toBeTruthy();

      // Three in-progress polls (well past the old fixed ~13s deadline), then the persisted turn.
      await act(async () => {
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
    // A terminal failure means the partial reply can never become complete, so do not leave a
    // confident but truncated claim in the chat.
    expect(screen.queryByText("Your bio currently has thr")).toBeNull();
    expect(screen.getByText("Sorry, I ran into a problem. Please try again.")).toBeTruthy();
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
      expect(screen.queryByText("Your bio currently has thr")).toBeNull();
      expect(screen.getByText("Sorry, I ran into a problem. Please try again.")).toBeTruthy();
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
      expect(screen.queryByText("Your bio currently has thr")).toBeNull();
      expect(screen.getByText("Sorry, I ran into a problem. Please try again.")).toBeTruthy();
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

  it("restores the working state while a reset reply is retried", async () => {
    let continueRetry: (() => void) | undefined;
    streamAgentMessage.mockImplementation(async (_messages, handlers = {}) => {
      handlers.onToken?.("Staged. Confirm that card.");
      handlers.onReset?.();
      await new Promise<void>((resolve) => {
        continueRetry = resolve;
      });
      handlers.onToken?.("That change wasn't prepared.");
      return {
        reply: "That change wasn't prepared.",
        proposedAction: null,
        proposalMessageId: null,
        objects: [],
        suggestions: [],
        conversationId: "conv1",
      };
    });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("update my bio");

    await waitFor(() => expect(screen.getByRole("status", { name: "Working on it" })).toBeTruthy());
    expect(screen.queryByText("Staged. Confirm that card.")).toBeNull();

    act(() => continueRetry?.());
    await waitFor(() => expect(screen.getByText("That change wasn't prepared.")).toBeTruthy());
    expect(screen.queryByRole("status", { name: "Working on it" })).toBeNull();
  });

  it("shows the fallback when a reset retry fails before sending more text", async () => {
    streamAgentMessage.mockImplementation((_messages, handlers = {}) => {
      handlers.onToken?.("Staged. Confirm that card.");
      handlers.onReset?.();
      return Promise.reject(new Error("Retry failed."));
    });
    fetchAgentTurnStatus.mockResolvedValue({ status: "failed" });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("update my bio");

    await waitFor(() => expect(screen.getByText("Sorry, I ran into a problem. Please try again.")).toBeTruthy());
    expect(screen.queryByText("Staged. Confirm that card.")).toBeNull();
    expect(showAlert).toHaveBeenCalledWith("Retry failed.", "error");
    expect(fetchAgentTurnStatus).toHaveBeenCalledWith(sentClientTurnId());
  });

  it("discards replacement text when a reset retry fails after streaming", async () => {
    streamAgentMessage.mockImplementation((_messages, handlers = {}) => {
      handlers.onToken?.("Staged. Confirm that card.");
      handlers.onReset?.();
      handlers.onToken?.("Staged again. Confirm below.");
      return Promise.reject(new Error("Retry failed."));
    });
    fetchAgentTurnStatus.mockResolvedValue({ status: "failed" });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("update my bio");

    await waitFor(() => expect(screen.getByText("Sorry, I ran into a problem. Please try again.")).toBeTruthy());
    expect(screen.queryByText("Staged. Confirm that card.")).toBeNull();
    expect(screen.queryByText("Staged again. Confirm below.")).toBeNull();
  });

  it("shows the server's rate-limit explanation in the chat instead of the generic failure", async () => {
    // The seller hasn't broken anything — they've spent their hourly agent budget. Both the alert
    // and the assistant bubble have to say so, since the generic "Sorry, I ran into a problem" sent
    // sellers clearing browser data and emailing support over a limit that clears itself.
    const explanation =
      "You've used all 30 agent requests for this hour (sending a message and confirming a change both count). " +
      "You can continue in 15 minutes — nothing is wrong with your account or your store.";
    streamAgentMessage.mockRejectedValue(new RateLimitError(explanation, 900));

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("what does my bio say");

    await waitFor(() => expect(screen.getByText(explanation)).toBeTruthy());
    expect(showAlert).toHaveBeenCalledWith(explanation, "warning");
    expect(screen.queryByText("Sorry, I ran into a problem. Please try again.")).toBeNull();
    // A refused request never started a turn server-side, so there is nothing to recover.
    expect(fetchAgentTurnStatus).not.toHaveBeenCalled();
  });

  it("sends a fresh client turn id with every turn", async () => {
    streamAgentMessage.mockResolvedValue({
      reply: "ok",
      proposedAction: null,
      proposalMessageId: null,
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

  const streamTurnWithAction = (
    proposedAction: import("$app/data/agent").ProposedAction,
    proposalMessageId: string | null = "message1",
  ) => {
    streamAgentMessage.mockResolvedValue({
      reply: "I've prepared the page edit.",
      proposedAction,
      proposalMessageId,
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
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    const iframe = await screen.findByTitle<HTMLIFrameElement>("Preview of your page after this change");
    // Loaded by URL (never srcdoc) so the staged document's response carries the custom-page CSP
    // header — inlined via srcdoc it would inherit the dashboard's CSP, which blocks the page's
    // inline scripts.
    expect(iframe.getAttribute("src")).toBe("/internal/agent/custom_html_previews/token123");
    expect(iframe.hasAttribute("srcdoc")).toBe(false);
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

  it("shows why a preview failed as a prominent alert and keeps Confirm disabled", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockRejectedValue(
      new Error("The snippet to replace no longer appears in the current page."),
    );

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    // The failure is why Confirm is disabled, so it renders as an alert naming the cause and the
    // way out — not a muted footnote (gumroad-private#1251).
    await waitFor(() =>
      expect(
        screen.getByText("This change can't be applied: The snippet to replace no longer appears in the current page."),
      ).toBeTruthy(),
    );
    expect(screen.getByRole("alert")).toBeTruthy();
    expect(screen.getByText("Ask the agent to re-read the page and propose the change again.")).toBeTruthy();
    // An invalid proposal would fail on apply too — Confirm stays off; Dismiss remains the way out.
    expect(screen.getByText("Confirm").closest("button")?.disabled).toBe(true);
    expect(screen.getByText("Dismiss").closest("button")?.disabled).toBe(false);
  });

  it("collapses an applied proposal into a compact card with the details behind Review", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");
    executeAgentAction.mockResolvedValue({ message: "Done.", object: null });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await screen.findByTitle("Preview of your page after this change");
    fireEvent.click(screen.getByText("Confirm"));

    // The full card (Confirm/Dismiss) collapses to a one-line applied record.
    await waitFor(() => expect(screen.getByText("Applied")).toBeTruthy());
    expect(executeAgentAction).toHaveBeenCalledWith(customHtmlAction, "message1", "conv1");
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

  it("shows a rate-limited confirmation as a warning rather than a failed change", async () => {
    // Confirming spends the same hourly budget as sending, so a 429 here is also a wait-it-out
    // limit. Presenting it as an error (red) would tell the seller their change failed, when it
    // simply hasn't been attempted yet.
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");
    const explanation =
      "You've used all 30 agent requests for this hour (sending a message and confirming a change both count). " +
      "You can continue in 15 minutes — nothing is wrong with your account or your store.";
    executeAgentAction
      .mockRejectedValueOnce(new RateLimitError(explanation, 900))
      .mockResolvedValueOnce({ message: "Done.", object: null });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await screen.findByTitle("Preview of your page after this change");
    fireEvent.click(screen.getByText("Confirm"));

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith(explanation, "warning"));
    // The proposal and its explanation remain together after the global toast disappears.
    expect(screen.getByText(explanation)).toBeTruthy();
    expect(screen.getByText("Confirm")).toBeTruthy();
    expect(screen.queryByText("Applied")).toBeNull();

    // Retrying clears the stale warning; a successful retry collapses the proposal as applied.
    fireEvent.click(screen.getByText("Confirm"));
    await waitFor(() => expect(screen.getByText("Applied")).toBeTruthy());
    expect(screen.queryByText(explanation)).toBeNull();
  });

  it("still shows a genuinely failed confirmation as an error", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");
    executeAgentAction.mockRejectedValue(new Error("That change couldn't be applied."));

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await screen.findByTitle("Preview of your page after this change");
    fireEvent.click(screen.getByText("Confirm"));

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("That change couldn't be applied.", "error"));
  });

  it("keeps a server-acknowledged retry-safe rejection confirmable", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");
    executeAgentAction.mockRejectedValue(new AgentActionError("You don't have permission to do that.", null, true));

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await screen.findByTitle("Preview of your page after this change");
    fireEvent.click(screen.getByText("Confirm"));

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("You don't have permission to do that.", "error"));
    expect(screen.getByText("Confirm")).toBeTruthy();
    expect(screen.getByText("Dismiss")).toBeTruthy();
    expect(screen.queryByText("Applying…")).toBeNull();
    expect(screen.queryByText("Applied")).toBeNull();
    expect(screen.queryByText("Outcome unknown")).toBeNull();
    expect(screen.queryByText("You don't have permission to do that.")).toBeNull();
    expect(fetchAgentActionStatus).not.toHaveBeenCalled();

    fireEvent.click(screen.getByText("Confirm"));
    await waitFor(() => expect(executeAgentAction).toHaveBeenCalledTimes(2));
  });

  it("keeps a binding mismatch non-confirmable", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");
    executeAgentAction.mockRejectedValue(
      new AgentActionError(
        "That confirmation doesn't match a pending proposal. Ask the agent to prepare it again.",
        null,
      ),
    );

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await screen.findByTitle("Preview of your page after this change");
    fireEvent.click(screen.getByText("Confirm"));

    await waitFor(() => expect(screen.getByText("Not applied")).toBeTruthy());
    expect(showAlert).toHaveBeenCalledWith(
      "That confirmation doesn't match a pending proposal. Ask the agent to prepare it again.",
      "error",
    );
    expect(screen.queryByText("Confirm")).toBeNull();
    expect(screen.queryByText("Dismiss")).toBeNull();
    expect(fetchAgentActionStatus).not.toHaveBeenCalled();
  });

  it("makes an unknown confirmation outcome non-confirmable without waiting for reload", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");
    executeAgentAction.mockRejectedValue(new AgentActionError("The refund result could not be confirmed.", "unknown"));
    fetchAgentActionStatus.mockResolvedValue({ actionStatus: "unknown", objects: [] });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await screen.findByTitle("Preview of your page after this change");
    fireEvent.click(screen.getByText("Confirm"));

    await waitFor(() => expect(screen.getByText("Outcome unknown")).toBeTruthy());
    expect(showAlert).toHaveBeenCalledWith("The refund result could not be confirmed.", "error");
    expect(screen.queryByText("Confirm")).toBeNull();
    expect(screen.queryByText("Dismiss")).toBeNull();
  });

  it("reconciles an executing confirmation another tab applies", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");
    executeAgentAction.mockRejectedValue(
      new AgentActionError("That proposal has already been confirmed.", "executing"),
    );
    fetchAgentActionStatus.mockResolvedValue({
      actionStatus: "applied",
      objects: [{ type: "product", title: "Updated product", fields: [] }],
    });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await screen.findByTitle("Preview of your page after this change");
    fireEvent.click(screen.getByText("Confirm"));

    await waitFor(() => expect(screen.getByText("Applied")).toBeTruthy());
    expect(screen.getByText("Updated product")).toBeTruthy();
    expect(fetchAgentActionStatus).toHaveBeenCalledWith("message1", expect.any(AbortSignal));
    expect(showAlert).toHaveBeenCalledWith("That proposal has already been confirmed.", "error");
    expect(screen.queryByText("Confirm")).toBeNull();
    expect(screen.queryByText("Dismiss")).toBeNull();
  });

  it("reconciles the exact proposal when the execute response is lost", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");
    executeAgentAction.mockRejectedValue(new ResponseError());
    fetchAgentActionStatus.mockResolvedValue({
      actionStatus: "applied",
      objects: [{ type: "product", title: "Updated after lost response", fields: [] }],
    });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await screen.findByTitle("Preview of your page after this change");
    fireEvent.click(screen.getByText("Confirm"));

    await waitFor(() => expect(screen.getByText("Applied")).toBeTruthy());
    expect(screen.getByText("Updated after lost response")).toBeTruthy();
    expect(fetchAgentActionStatus).toHaveBeenCalledWith("message1", expect.any(AbortSignal));
    expect(screen.queryByText("Confirm")).toBeNull();
  });

  it("reconciles the exact proposal when the execute response is unparseable", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");
    executeAgentAction.mockRejectedValue(new SyntaxError("Unexpected end of JSON input"));
    fetchAgentActionStatus.mockResolvedValue({
      actionStatus: "applied",
      objects: [{ type: "product", title: "Updated after malformed response", fields: [] }],
    });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await screen.findByTitle("Preview of your page after this change");
    fireEvent.click(screen.getByText("Confirm"));

    await waitFor(() => expect(screen.getByText("Applied")).toBeTruthy());
    expect(screen.getByText("Updated after malformed response")).toBeTruthy();
    expect(fetchAgentActionStatus).toHaveBeenCalledWith("message1", expect.any(AbortSignal));
    expect(showAlert).toHaveBeenCalledWith("Unexpected end of JSON input", "error");
    expect(screen.queryByText("Confirm")).toBeNull();
  });

  it("keeps an id-less ambiguous confirmation non-confirmable", async () => {
    streamTurnWithAction(customHtmlAction, null);
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");
    executeAgentAction.mockRejectedValue(new SyntaxError("Unexpected end of JSON input"));

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await screen.findByTitle("Preview of your page after this change");
    fireEvent.click(screen.getByText("Confirm"));

    await waitFor(() => expect(screen.getByText("Outcome unknown")).toBeTruthy());
    expect(screen.queryByText("Confirm")).toBeNull();
    expect(screen.queryByText("Dismiss")).toBeNull();
    expect(fetchAgentActionStatus).not.toHaveBeenCalled();
  });

  it("refreshes result objects when the server reports an already-applied proposal", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");
    executeAgentAction.mockRejectedValue(new AgentActionError("That proposal was already applied.", "applied"));
    fetchAgentActionStatus.mockResolvedValue({
      actionStatus: "applied",
      objects: [{ type: "product", title: "Persisted result object", fields: [] }],
    });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");

    await screen.findByTitle("Preview of your page after this change");
    fireEvent.click(screen.getByText("Confirm"));

    await waitFor(() => expect(screen.getByText("Persisted result object")).toBeTruthy());
    expect(screen.getByText("Applied")).toBeTruthy();
    expect(fetchAgentActionStatus).toHaveBeenCalledWith("message1", expect.any(AbortSignal));
  });

  it("does not downgrade an applied response when its result-object refresh never settles", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");
    executeAgentAction.mockRejectedValue(new AgentActionError("That proposal was already applied.", "applied"));
    fetchAgentActionStatus.mockReturnValue(new Promise(() => {}));

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");
    await screen.findByTitle("Preview of your page after this change");

    vi.useFakeTimers();
    try {
      fireEvent.click(screen.getByText("Confirm"));
      await act(async () => {
        await vi.advanceTimersByTimeAsync(0);
      });

      expect(screen.getByText("Applied")).toBeTruthy();
      expect(fetchAgentActionStatus).toHaveBeenCalledTimes(1);

      await act(async () => {
        await vi.advanceTimersByTimeAsync(ACTION_STATUS_RECONCILIATION_DEADLINE_MS);
      });

      expect(screen.getByText("Applied")).toBeTruthy();
      expect(screen.queryByText("Outcome unknown")).toBeNull();
    } finally {
      vi.useRealTimers();
    }
  });

  it("does not downgrade an applied response when its result-object refresh reports a non-applied state", async () => {
    streamTurnWithAction(customHtmlAction);
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");
    executeAgentAction.mockRejectedValue(new AgentActionError("That proposal was already applied.", "applied"));
    fetchAgentActionStatus.mockResolvedValue({ actionStatus: "unknown", objects: [] });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("change my headline");
    await screen.findByTitle("Preview of your page after this change");

    vi.useFakeTimers();
    try {
      fireEvent.click(screen.getByText("Confirm"));
      await act(async () => {
        await vi.advanceTimersByTimeAsync(ACTION_STATUS_RECONCILIATION_DEADLINE_MS);
      });

      expect(fetchAgentActionStatus).toHaveBeenCalledTimes(20);
      expect(screen.getByText("Applied")).toBeTruthy();
      expect(screen.queryByText("Outcome unknown")).toBeNull();
      expect(screen.queryByText("Confirm")).toBeNull();
    } finally {
      vi.useRealTimers();
    }
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
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");

    render(<AgentChat greeting="Hi" suggestions={[]} />);

    await waitFor(() => expect(screen.getByText("Dismissed")).toBeTruthy());
    expect(fetchCustomHtmlProposalPreview).not.toHaveBeenCalled();
    // A dismissed change never touched the page, so the server can still render exactly what the
    // seller evaluated — Review fetches it lazily.
    fireEvent.click(screen.getByText("Review"));
    await screen.findByTitle("Preview of your page after this change");
    expect(fetchCustomHtmlProposalPreview).toHaveBeenCalledTimes(1);
  });

  it("reconciles a hydrated executing proposal to its stable unknown outcome", async () => {
    fetchLatestAgentConversation.mockReset().mockResolvedValue({
      id: "conv1",
      title: null,
      messages: [
        {
          role: "assistant",
          content: "Applying your page edit.",
          proposed_action: customHtmlAction,
          proposal_message_id: "message1",
          action_status: "executing",
        },
      ],
    });
    fetchAgentActionStatus.mockResolvedValue({ actionStatus: "unknown", objects: [] });

    render(<AgentChat greeting="Hi" suggestions={[]} />);

    await waitFor(() => expect(screen.getByText("Outcome unknown")).toBeTruthy());
    expect(fetchAgentActionStatus).toHaveBeenCalledWith("message1", expect.any(AbortSignal));
    expect(screen.queryByText("Confirm")).toBeNull();
    expect(screen.queryByText("Dismiss")).toBeNull();
  });

  it("retries a transient action-status read before using the persisted state", async () => {
    fetchLatestAgentConversation.mockReset().mockResolvedValue({
      id: "conv1",
      title: null,
      messages: [
        {
          role: "assistant",
          content: "Confirm this page edit.",
          proposed_action: customHtmlAction,
          proposal_message_id: "message1",
          action_status: "executing",
        },
      ],
    });
    fetchAgentActionStatus
      .mockRejectedValueOnce(new ResponseError())
      .mockResolvedValue({ actionStatus: "pending", objects: [] });
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");

    vi.useFakeTimers();
    try {
      render(<AgentChat greeting="Hi" suggestions={[]} />);
      await act(async () => {
        await vi.advanceTimersByTimeAsync(0);
      });
      expect(fetchAgentActionStatus).toHaveBeenCalledTimes(1);

      await act(async () => {
        await vi.advanceTimersByTimeAsync(ACTION_STATUS_RECONCILIATION_INTERVAL_MS);
      });

      expect(fetchAgentActionStatus).toHaveBeenCalledTimes(2);
      expect(screen.getByText("Confirm")).toBeTruthy();
      expect(screen.queryByText("Outcome unknown")).toBeNull();
    } finally {
      vi.useRealTimers();
    }
  });

  it("reconciles an executing proposal through React StrictMode's setup cycle", async () => {
    fetchLatestAgentConversation.mockReset().mockResolvedValue({
      id: "conv1",
      title: null,
      messages: [
        {
          role: "assistant",
          content: "Confirm this page edit.",
          proposed_action: customHtmlAction,
          proposal_message_id: "message1",
          action_status: "executing",
        },
      ],
    });
    fetchAgentActionStatus.mockResolvedValue({ actionStatus: "applied", objects: [] });

    render(
      <React.StrictMode>
        <AgentChat greeting="Hi" suggestions={[]} />
      </React.StrictMode>,
    );

    await waitFor(() => expect(screen.getByText("Applied")).toBeTruthy());
    expect(fetchAgentActionStatus).toHaveBeenCalledWith("message1", expect.any(AbortSignal));
  });

  it("settles locally when an action-status request never resolves", async () => {
    fetchLatestAgentConversation.mockReset().mockResolvedValue({
      id: "conv1",
      title: null,
      messages: [
        {
          role: "assistant",
          content: "Confirm this page edit.",
          proposed_action: customHtmlAction,
          proposal_message_id: "message1",
          action_status: "executing",
        },
      ],
    });
    fetchAgentActionStatus.mockReturnValue(new Promise(() => {}));

    vi.useFakeTimers();
    try {
      render(<AgentChat greeting="Hi" suggestions={[]} />);
      await act(async () => {
        await vi.advanceTimersByTimeAsync(0);
      });
      expect(fetchAgentActionStatus).toHaveBeenCalledTimes(1);
      const abortSignal = fetchAgentActionStatus.mock.calls[0]?.[1];

      await act(async () => {
        await vi.advanceTimersByTimeAsync(ACTION_STATUS_RECONCILIATION_DEADLINE_MS);
      });

      expect(abortSignal?.aborted).toBe(true);
      expect(screen.getByText("Outcome unknown")).toBeTruthy();
    } finally {
      vi.useRealTimers();
    }
  });

  it("aborts an in-flight action-status request when unmounted", async () => {
    fetchLatestAgentConversation.mockReset().mockResolvedValue({
      id: "conv1",
      title: null,
      messages: [
        {
          role: "assistant",
          content: "Confirm this page edit.",
          proposed_action: customHtmlAction,
          proposal_message_id: "message1",
          action_status: "executing",
        },
      ],
    });
    fetchAgentActionStatus.mockReturnValue(new Promise(() => {}));

    vi.useFakeTimers();
    try {
      const view = render(<AgentChat greeting="Hi" suggestions={[]} />);
      await act(async () => {
        await vi.advanceTimersByTimeAsync(0);
      });
      expect(fetchAgentActionStatus).toHaveBeenCalledTimes(1);
      const abortSignal = fetchAgentActionStatus.mock.calls[0]?.[1];

      view.unmount();

      expect(abortSignal?.aborted).toBe(true);
      await act(async () => {
        await vi.advanceTimersByTimeAsync(ACTION_STATUS_RECONCILIATION_DEADLINE_MS);
      });
      expect(fetchAgentActionStatus).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("settles after twenty executing responses", async () => {
    fetchLatestAgentConversation.mockReset().mockResolvedValue({
      id: "conv1",
      title: null,
      messages: [
        {
          role: "assistant",
          content: "Confirm this page edit.",
          proposed_action: customHtmlAction,
          proposal_message_id: "message1",
          action_status: "executing",
        },
      ],
    });
    fetchAgentActionStatus.mockResolvedValue({ actionStatus: "executing", objects: [] });

    vi.useFakeTimers();
    try {
      render(<AgentChat greeting="Hi" suggestions={[]} />);
      await act(async () => {
        await vi.advanceTimersByTimeAsync(0);
      });
      await act(async () => {
        await vi.advanceTimersByTimeAsync(ACTION_STATUS_RECONCILIATION_DEADLINE_MS);
      });

      expect(fetchAgentActionStatus).toHaveBeenCalledTimes(20);
      expect(screen.getByText("Outcome unknown")).toBeTruthy();
    } finally {
      vi.useRealTimers();
    }
  });

  it("keeps polling through the Rack horizon when the twentieth response is applied", async () => {
    fetchLatestAgentConversation.mockReset().mockResolvedValue({
      id: "conv1",
      title: null,
      messages: [
        {
          role: "assistant",
          content: "Confirm this page edit.",
          proposed_action: customHtmlAction,
          proposal_message_id: "message1",
          action_status: "executing",
        },
      ],
    });
    for (let attempt = 0; attempt < 19; attempt++) {
      fetchAgentActionStatus.mockResolvedValueOnce({ actionStatus: "executing", objects: [] });
    }
    fetchAgentActionStatus.mockResolvedValue({
      actionStatus: "applied",
      objects: [{ type: "product", title: "Applied at the request horizon", fields: [] }],
    });

    vi.useFakeTimers();
    try {
      render(<AgentChat greeting="Hi" suggestions={[]} />);
      await act(async () => {
        await vi.advanceTimersByTimeAsync(0);
      });
      await act(async () => {
        await vi.advanceTimersByTimeAsync(ACTION_STATUS_RACK_HORIZON_MS);
      });

      expect(fetchAgentActionStatus).toHaveBeenCalledTimes(19);
      expect(screen.getByText("Applying…")).toBeTruthy();

      await act(async () => {
        await vi.advanceTimersByTimeAsync(ACTION_STATUS_FINAL_POLL_DELAY_MS);
      });

      expect(fetchAgentActionStatus).toHaveBeenCalledTimes(20);
      expect(screen.getByText("Applied")).toBeTruthy();
      expect(screen.getByText("Applied at the request horizon")).toBeTruthy();
    } finally {
      vi.useRealTimers();
    }
  });

  it("makes a proposal confirmable again when the winning request releases its claim", async () => {
    fetchLatestAgentConversation.mockReset().mockResolvedValue({
      id: "conv1",
      title: null,
      messages: [
        {
          role: "assistant",
          content: "Confirm this page edit.",
          proposed_action: customHtmlAction,
          proposal_message_id: "message1",
          action_status: "executing",
        },
      ],
    });
    fetchAgentActionStatus.mockResolvedValue({ actionStatus: "pending", objects: [] });
    fetchCustomHtmlProposalPreview.mockResolvedValue("/internal/agent/custom_html_previews/token123");

    render(<AgentChat greeting="Hi" suggestions={[]} />);

    await waitFor(() => expect(screen.getByText("Confirm")).toBeTruthy());
    expect(fetchAgentActionStatus).toHaveBeenCalledWith("message1", expect.any(AbortSignal));
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

describe("AgentChat locked state", () => {
  const locked = { heading: "Agent unlocks after your first payout", explanation: "Once you have $100 in sales." };

  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("states the bar and disables every control that would hit a 401", () => {
    render(<AgentChat greeting="Hi" suggestions={["List my products"]} locked={locked} />);

    expect(screen.getByText(locked.heading)).toBeTruthy();
    expect(screen.getByText(locked.explanation)).toBeTruthy();
    expect(screen.getByLabelText("Message").hasAttribute("disabled")).toBe(true);
    expect(screen.getByLabelText("Send").hasAttribute("disabled")).toBe(true);
    // Starter chips would each fire a turn, so they are replaced by the notice rather than disabled.
    expect(screen.queryByText("List my products")).toBeNull();
  });

  it("does not resume a conversation an ineligible seller cannot have", () => {
    render(<AgentChat greeting="Hi" suggestions={[]} locked={locked} />);

    expect(fetchLatestAgentConversation).not.toHaveBeenCalled();
  });

  it("sends nothing even if a submit is forced through", () => {
    render(<AgentChat greeting="Hi" suggestions={[]} locked={locked} />);

    const input = screen.getByLabelText("Message");
    fireEvent.change(input, { target: { value: "raise my prices" } });
    const form = input.closest("form");
    if (!form) throw new Error("composer form not rendered");
    fireEvent.submit(form);

    expect(streamAgentMessage).not.toHaveBeenCalled();
  });

  it("keeps the composer live when the seller is eligible", () => {
    fetchLatestAgentConversation.mockResolvedValueOnce(null);
    render(<AgentChat greeting="Hi" suggestions={["List my products"]} />);

    expect(screen.queryByText(locked.heading)).toBeNull();
    expect(screen.getByLabelText("Message").hasAttribute("disabled")).toBe(false);
    expect(screen.getByText("List my products")).toBeTruthy();
  });
});
