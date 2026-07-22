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

// A Response whose body stays open under manual control: chunks are pushed (and the stream closed)
// via the returned controller. Models a connection that goes silent or never delivers its EOF.
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
    // Rejects any pending read, the way aborting the underlying fetch does.
    error: (reason: unknown) => controller.error(reason),
  };
};

const frame = (event: string, data: object) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;

const MESSAGES = [{ role: "user" as const, content: "hello" }];

// Mirrors STREAM_INACTIVITY_TIMEOUT_MS in $app/data/agent — how long the stream may stay silent
// before the client treats the connection as dead.
const INACTIVITY_TIMEOUT_MS = 130_000;

describe("streamAgentMessage", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.useRealTimers();
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

  it("throws AgentStreamInterruptedError when the stream goes silent without a done frame", async () => {
    // The bug this guards against: the server finishes the turn (200 OK logged), but the client
    // never receives the trailing frames OR the connection close — reader.read() just stays
    // pending. The inactivity timeout must surface that as an interruption so the caller enters
    // turn-status recovery instead of hanging with the composer locked.
    vi.useFakeTimers();
    const stream = openSseResponse();
    request.mockResolvedValue(stream.response);
    const onToken = vi.fn<(text: string) => void>();

    const promise = streamAgentMessage(MESSAGES, { onToken });
    const expectation = expect(promise).rejects.toBeInstanceOf(AgentStreamInterruptedError);
    stream.push(frame("token", { text: "Want me to " }));
    await vi.advanceTimersByTimeAsync(INACTIVITY_TIMEOUT_MS);
    await expectation;
    expect(onToken).toHaveBeenCalledWith("Want me to ");
  });

  it("throws AgentStreamInterruptedError when the connection stalls before response headers arrive", async () => {
    // The server holds response headers until its first stream write, so a connection that dies
    // before that leaves the fetch itself pending forever — the inactivity clock must cover the
    // pre-header phase too, not just body reads.
    vi.useFakeTimers();
    request.mockReturnValue(new Promise<never>(() => {}));

    const promise = streamAgentMessage(MESSAGES);
    const expectation = expect(promise).rejects.toBeInstanceOf(AgentStreamInterruptedError);
    await vi.advanceTimersByTimeAsync(INACTIVITY_TIMEOUT_MS);
    await expectation;
  });

  it("treats server keepalive comments as activity and never surfaces them as events", async () => {
    // Tool-heavy turns can go minutes between real events; the server fills those stretches with
    // SSE comment frames. Each one must reset the inactivity clock (four quiet stretches here,
    // together well past the timeout) without producing tokens or other handler calls.
    vi.useFakeTimers();
    const stream = openSseResponse();
    request.mockResolvedValue(stream.response);
    const onToken = vi.fn<(text: string) => void>();

    const promise = streamAgentMessage(MESSAGES, { onToken });
    const expectation = expect(promise).resolves.toMatchObject({ reply: "All done." });
    for (let i = 0; i < 4; i++) {
      await vi.advanceTimersByTimeAsync(INACTIVITY_TIMEOUT_MS - 1000);
      stream.push(": heartbeat\n\n");
    }
    stream.push(frame("done", { reply: "All done.", proposed_action: null }));
    stream.close();
    await expectation;
    expect(onToken).not.toHaveBeenCalled();
  });

  it("does not treat a slow but active stream as stalled — each frame resets the inactivity clock", async () => {
    vi.useFakeTimers();
    const stream = openSseResponse();
    request.mockResolvedValue(stream.response);

    const promise = streamAgentMessage(MESSAGES);
    const expectation = expect(promise).resolves.toMatchObject({ reply: "Want me to pull up?" });
    // Two quiet stretches whose total exceeds the timeout, but with a frame between them — the
    // clock must restart on every chunk, so neither stretch alone trips it.
    await vi.advanceTimersByTimeAsync(INACTIVITY_TIMEOUT_MS - 1000);
    stream.push(frame("token", { text: "Want me to " }));
    await vi.advanceTimersByTimeAsync(INACTIVITY_TIMEOUT_MS - 1000);
    stream.push(frame("done", { reply: "Want me to pull up?", proposed_action: null }));
    stream.close();
    await expectation;
  });

  it("passes the abort signal through and swallows the abandoned read's late rejection", async () => {
    vi.useFakeTimers();
    const stream = openSseResponse();
    request.mockResolvedValue(stream.response);
    const controller = new AbortController();

    const promise = streamAgentMessage(MESSAGES, {}, null, null, controller.signal);
    const expectation = expect(promise).rejects.toBeInstanceOf(AgentStreamInterruptedError);
    await vi.advanceTimersByTimeAsync(INACTIVITY_TIMEOUT_MS);
    await expectation;

    expect(request).toHaveBeenLastCalledWith(expect.objectContaining({ abortSignal: controller.signal }));

    // The caller aborts the connection once the turn settles, which rejects the read the timeout
    // abandoned. Nothing awaits that read anymore — its rejection must be swallowed internally,
    // or it surfaces as an unhandled rejection (which vitest reports as a run-level error).
    controller.abort();
    stream.error(new DOMException("The operation was aborted.", "AbortError"));
    await vi.advanceTimersByTimeAsync(0);
  });

  it("resolves the turn on the done frame even when the connection never closes", async () => {
    const stream = openSseResponse();
    request.mockResolvedValue(stream.response);

    const promise = streamAgentMessage(MESSAGES);
    stream.push(frame("done", { reply: "Want me to pull up?", proposed_action: null, conversation_id: "conv1" }));
    // No close(): the stream stays open, but `done` is terminal so the turn must resolve anyway.
    const result = await promise;
    expect(result.reply).toBe("Want me to pull up?");
    expect(result.conversationId).toBe("conv1");
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
