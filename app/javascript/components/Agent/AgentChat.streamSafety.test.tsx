// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("$app/utils/request", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/utils/request")>();
  return { ...actual, request: vi.fn() };
});

vi.mock("$app/data/agent", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/data/agent")>();
  return {
    ...actual,
    fetchLatestAgentConversation: vi.fn().mockResolvedValue(null),
    fetchAgentActionStatus: vi.fn(),
    fetchAgentTurnStatus: vi.fn(),
    fetchCustomHtmlProposalPreview: vi.fn(),
    executeAgentAction: vi.fn(),
  };
});

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

vi.stubGlobal("Routes", {
  internal_agent_messages_stream_path: () => "/internal/agent/messages/stream",
});

const { request } = vi.mocked(await import("$app/utils/request"));
const { executeAgentAction } = vi.mocked(await import("$app/data/agent"), { partial: true });
const { showAlert } = vi.mocked(await import("$app/components/server-components/Alert"));
const { AgentChat } = await import("$app/components/Agent/AgentChat");

const openSseResponse = () => {
  let controller!: ReadableStreamDefaultController<Uint8Array>;
  const body = new ReadableStream<Uint8Array>({
    start(c) {
      controller = c;
    },
  });
  const encoder = new TextEncoder();
  return {
    response: new Response(body, { headers: { "content-type": "text/event-stream" } }),
    push: (chunk: string) => controller.enqueue(encoder.encode(chunk)),
    close: () => controller.close(),
    error: (reason: unknown) => controller.error(reason),
  };
};

const frame = (event: string, data: object) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;

const doneFrame = (reply: string) =>
  frame("done", { reply, proposed_action: null, suggestions: [], conversation_id: "conv1" });

const sendMessage = async (text: string) => {
  const calls = request.mock.calls.length;
  fireEvent.change(screen.getByLabelText("Message"), { target: { value: text } });
  fireEvent.click(screen.getByLabelText("Send"));
  await waitFor(() => expect(request.mock.calls.length).toBeGreaterThan(calls));
};

const composerLocked = () => screen.getByLabelText("Message").hasAttribute("disabled");

describe("AgentChat stream ownership after early done", () => {
  beforeEach(() => {
    request.mockReset();
    showAlert.mockReset();
  });

  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("keeps same-turn late chips when the promise later settles with empty suggestions", async () => {
    const stream = openSseResponse();
    request.mockResolvedValue(stream.response);

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("how are sales");
    expect(composerLocked()).toBe(true);

    await act(async () => {
      stream.push(frame("token", { text: "You have one product." }));
      stream.push(doneFrame("You have one product."));
    });
    await waitFor(() => expect(screen.getByText("You have one product.")).toBeTruthy());
    await waitFor(() => expect(composerLocked()).toBe(false));

    await act(async () => {
      stream.push(frame("suggestions", { suggestions: ["Show my sales"] }));
    });
    await waitFor(() => expect(screen.getByLabelText("Suggested follow-ups").textContent).toContain("Show my sales"));

    await act(async () => {
      stream.close();
    });
    await waitFor(() => expect(screen.getByLabelText("Suggested follow-ups").textContent).toContain("Show my sales"));
    expect(showAlert).not.toHaveBeenCalled();
    expect(screen.queryByText("Sorry, I ran into a problem. Please try again.")).toBeNull();
  });

  it("does not turn a completed answer into an error on late EOF after done", async () => {
    const stream = openSseResponse();
    request.mockResolvedValue(stream.response);

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("how are sales");

    await act(async () => {
      stream.push(doneFrame("You have one product."));
    });
    await waitFor(() => expect(screen.getByText("You have one product.")).toBeTruthy());
    await waitFor(() => expect(composerLocked()).toBe(false));

    await act(async () => {
      stream.close();
    });
    await waitFor(() => expect(composerLocked()).toBe(false));
    expect(screen.getByText("You have one product.")).toBeTruthy();
    expect(screen.queryByText("Sorry, I ran into a problem. Please try again.")).toBeNull();
    expect(showAlert).not.toHaveBeenCalled();
  });

  it("ignores the old stream's late chips and EOF after a new send", async () => {
    const first = openSseResponse();
    const second = openSseResponse();
    request.mockResolvedValueOnce(first.response).mockResolvedValueOnce(second.response);

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("first");

    await act(async () => {
      first.push(doneFrame("First reply."));
    });
    await waitFor(() => expect(screen.getByText("First reply.")).toBeTruthy());
    await waitFor(() => expect(composerLocked()).toBe(false));

    await act(async () => {
      first.push(frame("suggestions", { suggestions: ["Old chip"] }));
    });
    await waitFor(() => expect(screen.getByText("Old chip")).toBeTruthy());

    await sendMessage("second");
    expect(composerLocked()).toBe(true);

    await act(async () => {
      first.push(frame("suggestions", { suggestions: ["Stale chip"] }));
      first.close();
    });
    expect(screen.queryByText("Stale chip")).toBeNull();
    expect(screen.queryByText("Old chip")).toBeNull();

    await act(async () => {
      second.push(frame("token", { text: "Second reply." }));
      second.push(doneFrame("Second reply."));
    });
    await waitFor(() => expect(screen.getByText("Second reply.")).toBeTruthy());
    await waitFor(() => expect(composerLocked()).toBe(false));

    await act(async () => {
      second.push(frame("suggestions", { suggestions: ["New chip"] }));
    });
    await waitFor(() => expect(screen.getByLabelText("Suggested follow-ups").textContent).toContain("New chip"));
    expect(screen.queryByText("Stale chip")).toBeNull();
    expect(screen.queryByText("Sorry, I ran into a problem. Please try again.")).toBeNull();
    expect(showAlert).not.toHaveBeenCalled();
  });

  it("keeps a proposal confirmed during the chip wait when the stream later settles", async () => {
    const stream = openSseResponse();
    request.mockResolvedValue(stream.response);
    executeAgentAction.mockResolvedValue({ message: "Created.", object: null });

    render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("make a 20% off code");

    await act(async () => {
      stream.push(
        frame("done", {
          reply: "Confirm the card below.",
          proposed_action: { type: "api_write", params: { endpoint: "create_offer_code" }, summary: "Create LAUNCH." },
          proposal_message_id: "msg1",
          suggestions: [],
          conversation_id: "conv1",
        }),
      );
    });
    await waitFor(() => expect(composerLocked()).toBe(false));
    fireEvent.click(screen.getByText("Confirm"));
    await waitFor(() => expect(screen.getByText("Applied")).toBeTruthy());

    await act(async () => {
      stream.push(frame("suggestions", { suggestions: ["Show my discount codes"] }));
      stream.close();
    });
    await waitFor(() =>
      expect(screen.getByLabelText("Suggested follow-ups").textContent).toContain("Show my discount codes"),
    );
    expect(screen.getByText("Applied")).toBeTruthy();
    expect(screen.queryByText("Confirm")).toBeNull();
    expect(executeAgentAction).toHaveBeenCalledTimes(1);
  });

  it("drops late callbacks after unmount without aborting the server's turn", async () => {
    const stream = openSseResponse();
    request.mockResolvedValue(stream.response);

    const view = render(<AgentChat greeting="Hi" suggestions={[]} />);
    await sendMessage("how are sales");
    await act(async () => {
      stream.push(doneFrame("You have one product."));
    });
    await waitFor(() => expect(screen.getByText("You have one product.")).toBeTruthy());

    view.unmount();

    // An abort would raise ClientDisconnected server-side and mark a still-generating turn failed.
    expect(request.mock.calls[0]?.[0]?.abortSignal?.aborted).toBe(false);
    expect(() => {
      stream.push(frame("suggestions", { suggestions: ["After unmount"] }));
      stream.close();
    }).not.toThrow();
    await act(async () => {
      await Promise.resolve();
    });
    expect(showAlert).not.toHaveBeenCalled();
  });
});
