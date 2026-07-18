import { afterEach, describe, expect, it, vi } from "vitest";

import { ResponseError } from "$app/utils/request";

vi.mock("$app/utils/request", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/utils/request")>();
  return { ...actual, request: vi.fn() };
});

vi.stubGlobal("Routes", {
  internal_agent_messages_stream_path: () => "/internal/agent/messages/stream",
  internal_agent_turn_status_path: (id: string) => `/internal/agent/turns/${id}`,
});

const { request } = vi.mocked(await import("$app/utils/request"));
const { AgentStreamInterruptedError, fetchAgentTurnStatus, streamAgentMessage } = await import("$app/data/agent");

// A real Response whose body streams the given SSE chunks. `fail` ends the stream by erroring the
// reader (a dropped connection) instead of a clean EOF.
const sseResponse = (chunks: string[], { fail = false } = {}) => {
  const encoder = new TextEncoder();
  const body = new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      if (!fail) controller.close();
    },
    // Erroring from pull (not start) lets the queued chunks reach the reader first, matching a
    // connection that delivered some frames and then dropped.
    pull(controller) {
      if (fail) controller.error(new TypeError("network error"));
    },
  });
  return new Response(body, { headers: { "content-type": "text/event-stream" } });
};

const frame = (event: string, data: object) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;

const MESSAGES = [{ role: "user" as const, content: "hello" }];

describe("streamAgentMessage", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("yields tokens as they arrive and resolves with the done frame's assembled turn", async () => {
    request.mockResolvedValue(
      sseResponse([
        frame("token", { text: "Want me to " }),
        frame("token", { text: "pull up" }),
        frame("done", {
          reply: "Want me to pull up what you have there now?",
          proposed_action: null,
          conversation_id: "conv1",
        }),
      ]),
    );
    const onToken = vi.fn<(text: string) => void>();

    const result = await streamAgentMessage(MESSAGES, { onToken });

    expect(onToken.mock.calls.map(([text]) => text)).toEqual(["Want me to ", "pull up"]);
    expect(result.reply).toBe("Want me to pull up what you have there now?");
    expect(result.conversationId).toBe("conv1");
  });

  it("throws AgentStreamInterruptedError when the stream ends without a done frame", async () => {
    request.mockResolvedValue(sseResponse([frame("token", { text: "Want me to " })]));
    const onToken = vi.fn();

    await expect(streamAgentMessage(MESSAGES, { onToken })).rejects.toBeInstanceOf(AgentStreamInterruptedError);
    expect(onToken).toHaveBeenCalledWith("Want me to ");
  });

  it("throws AgentStreamInterruptedError when the connection drops mid-stream", async () => {
    request.mockResolvedValue(sseResponse([frame("token", { text: "Want me to " })], { fail: true }));

    await expect(streamAgentMessage(MESSAGES)).rejects.toBeInstanceOf(AgentStreamInterruptedError);
  });

  it("returns the assembled turn when the connection drops only after the done frame", async () => {
    request.mockResolvedValue(
      sseResponse(
        [
          frame("token", { text: "Want me to " }),
          frame("done", { reply: "Want me to pull up?", proposed_action: null }),
        ],
        { fail: true },
      ),
    );

    const result = await streamAgentMessage(MESSAGES);
    expect(result.reply).toBe("Want me to pull up?");
  });

  it("throws AgentStreamInterruptedError when a frame arrives mangled", async () => {
    request.mockResolvedValue(sseResponse(["event: token\ndata: {not json\n\n"]));

    await expect(streamAgentMessage(MESSAGES)).rejects.toBeInstanceOf(AgentStreamInterruptedError);
  });

  it("passes a server-reported error event through as a plain ResponseError, not an interruption", async () => {
    request.mockResolvedValue(sseResponse([frame("error", { message: "Too many requests." })]));

    const error = await streamAgentMessage(MESSAGES).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResponseError);
    expect(error).not.toBeInstanceOf(AgentStreamInterruptedError);
    expect(error).toMatchObject({ message: "Too many requests." });
  });

  it("sends the client turn id with the stream request so the turn is recoverable by id", async () => {
    request.mockResolvedValue(
      sseResponse([frame("done", { reply: "Hi.", proposed_action: null, conversation_id: "conv1" })]),
    );

    await streamAgentMessage(MESSAGES, {}, null, "11111111-2222-4333-8444-555555555555");

    const call = request.mock.calls[request.mock.calls.length - 1]?.[0];
    expect(call && "data" in call ? call.data : undefined).toMatchObject({
      client_turn_id: "11111111-2222-4333-8444-555555555555",
    });
  });
});

describe("fetchAgentTurnStatus", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  const jsonResponse = (body: object) =>
    new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } });

  it("returns the persisted turn with its conversation id and stored message", async () => {
    request.mockResolvedValue(
      jsonResponse({
        success: true,
        status: "persisted",
        conversation_id: "conv1",
        message: { role: "assistant", content: "The full reply." },
      }),
    );

    const result = await fetchAgentTurnStatus("11111111-2222-4333-8444-555555555555");

    expect(request).toHaveBeenCalledWith(
      expect.objectContaining({ url: "/internal/agent/turns/11111111-2222-4333-8444-555555555555" }),
    );
    expect(result).toEqual({
      status: "persisted",
      conversation_id: "conv1",
      message: { role: "assistant", content: "The full reply." },
    });
  });

  it.each(["in_progress", "failed", "unknown"] as const)("returns a bare %s status", async (status) => {
    request.mockResolvedValue(jsonResponse({ success: true, status }));

    await expect(fetchAgentTurnStatus("11111111-2222-4333-8444-555555555555")).resolves.toEqual({ status });
  });

  it("throws when the server rejects the turn id", async () => {
    request.mockResolvedValue(jsonResponse({ success: false, error: "Invalid turn id." }));

    await expect(fetchAgentTurnStatus("nope")).rejects.toBeInstanceOf(ResponseError);
  });
});
