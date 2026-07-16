import { afterEach, describe, expect, it, vi } from "vitest";

import { ResponseError } from "$app/utils/request";

vi.mock("$app/utils/request", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/utils/request")>();
  return { ...actual, request: vi.fn() };
});

vi.stubGlobal("Routes", {
  internal_agent_messages_stream_path: () => "/internal/agent/messages/stream",
});

const { request } = vi.mocked(await import("$app/utils/request"));
const { AgentStreamInterruptedError, streamAgentMessage } = await import("$app/data/agent");

// A real Response whose body streams the given SSE chunks. `fail` ends the stream by erroring the
// reader (a dropped connection) instead of a clean EOF.
const sseResponse = (chunks: string[], { fail = false } = {}) => {
  const encoder = new TextEncoder();
  const body = new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      if (fail) controller.error(new TypeError("network error"));
      else controller.close();
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
    const onToken = vi.fn();

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
});
