import typia from "typia";

import { request, ResponseError } from "$app/utils/request";

export type ChatRole = "user" | "assistant";

export type ChatMessage = {
  role: ChatRole;
  content: string;
};

// A store change the agent has prepared. It is NOT applied until the seller confirms it, at which
// point we POST it back to the `actions` endpoint. The agent now stages every change as a single
// generic `api_write` (a real Gumroad API call it will replay after confirmation); `summary` is the
// human-readable description shown on the confirmation card, and `params` carries the endpoint id
// plus its path params and body so the server can replay the exact call.
export type ProposedAction = {
  type: "api_write";
  params: Record<string, unknown>;
  summary: string;
  // The operation being proposed (e.g. "Delete a discount code."), shown as the card heading.
  title?: string;
  // Humanized label/value rows for the confirmation card. Optional so older/streamed payloads without
  // them still validate; the card falls back to `summary` when absent.
  fields?: { label: string; value: string }[];
};

type SendMessageResponse =
  | { success: true; reply: string; proposed_action: ProposedAction | null; objects?: DisplayObject[] }
  | { success: false; error: string };

type ExecuteActionResponse = { success: boolean; message: string; object?: DisplayObject | null };

// A renderable object the agent looked up or changed (a product, discount, sale, payout, ...). The
// server builds these from the real API response, so they only ever contain data the creator can
// already see. The chat renders them inline as cards / a list beneath the message.
export type DisplayObject = {
  type: string;
  title: string;
  subtitle?: string | null;
  fields: { label: string; value: string }[];
  url?: string | null;
  copy?: string | null;
};

export const sendAgentMessage = async (
  messages: ChatMessage[],
): Promise<{ reply: string; proposedAction: ProposedAction | null; objects: DisplayObject[] }> => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_agent_messages_path(),
    data: { messages },
  });
  const json = typia.assert<SendMessageResponse>(await response.json());
  if (!json.success) throw new ResponseError(json.error);
  return { reply: json.reply, proposedAction: json.proposed_action, objects: json.objects ?? [] };
};

export const executeAgentAction = async (
  action: ProposedAction,
): Promise<{ message: string; object: DisplayObject | null }> => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_agent_actions_path(),
    data: { type: action.type, params: action.params },
  });
  const json = typia.assert<ExecuteActionResponse>(await response.json());
  if (!json.success) throw new ResponseError(json.message);
  return { message: json.message, object: json.object ?? null };
};

// Events the streaming endpoint emits, surfaced to the caller as they arrive so the UI can render a
// reply token-by-token and then show follow-up suggestions. `token` carries a chunk of reply text;
// `objects` / `proposedAction` mirror the buffered response; `suggestions` is the list of "what
// next" prompts shown at the end of the turn to keep the conversation going.
export type AgentStreamHandlers = {
  onToken?: (text: string) => void;
  // Discard any reply text streamed so far this turn — emitted when an intermediate tool-use turn
  // streamed preamble text that is not the final answer, so the UI clears it before the real reply.
  onReset?: () => void;
  onObjects?: (objects: DisplayObject[]) => void;
  onProposedAction?: (action: ProposedAction) => void;
  onSuggestions?: (suggestions: string[]) => void;
};

type StreamResult = {
  reply: string;
  proposedAction: ProposedAction | null;
  objects: DisplayObject[];
  suggestions: string[];
};

// Server-Sent Event payloads, validated per-event with typia so a malformed frame can't slip
// untyped data into the UI.
type TokenData = { text: string };
type ObjectsData = { objects: DisplayObject[] };
type ProposedActionData = { proposed_action: ProposedAction | null };
type SuggestionsData = { suggestions: string[] };
type ErrorData = { message: string };
type DoneData = {
  reply: string;
  proposed_action: ProposedAction | null;
  objects?: DisplayObject[];
  suggestions?: string[];
};

// Stream one conversation turn over Server-Sent Events. Calls the handlers as events arrive and
// resolves with the fully-assembled turn once the `done` event lands. Falls back to throwing a
// ResponseError (so the caller can show the same alert as the non-streaming path) on an `error`
// event or a transport failure.
export const streamAgentMessage = async (
  messages: ChatMessage[],
  handlers: AgentStreamHandlers = {},
): Promise<StreamResult> => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_agent_messages_stream_path(),
    data: { messages },
  });

  // request() only rejects 5xx/429, so a 4xx or an HTML response from auth/CSRF/authorization
  // middleware arrives here as a non-stream body. Treat anything that isn't an event-stream as an
  // error rather than silently recording a blank assistant reply (the buffered endpoint surfaced
  // these as errors too).
  const body = response.body;
  if (!response.ok || !response.headers.get("content-type")?.includes("text/event-stream") || !body) {
    throw new ResponseError();
  }

  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let proposedAction: ProposedAction | null = null;
  let objects: DisplayObject[] = [];
  let suggestions: string[] = [];
  let done: StreamResult | null = null;

  // One complete SSE frame ("event: <name>\n data: <json>\n"). Parse the event name + JSON data,
  // dispatch to the matching handler, and return the terminal result on the `done` event (null
  // otherwise) so the caller can record it in the function scope.
  const handleFrame = (frame: string): StreamResult | null => {
    let event = "message";
    const dataLines: string[] = [];
    for (const line of frame.split("\n")) {
      if (line.startsWith("event:")) event = line.slice(6).trim();
      else if (line.startsWith("data:")) dataLines.push(line.slice(5).trim());
    }
    if (dataLines.length === 0) return null;
    const raw: unknown = JSON.parse(dataLines.join("\n"));

    switch (event) {
      case "token": {
        const { text } = typia.assert<TokenData>(raw);
        handlers.onToken?.(text);
        return null;
      }
      case "reset": {
        // An intermediate tool-use turn streamed preamble text that isn't the final answer. Tell the
        // UI to drop what it has shown so far so the next turn's text replaces it cleanly.
        handlers.onReset?.();
        return null;
      }
      case "objects": {
        objects = typia.assert<ObjectsData>(raw).objects;
        handlers.onObjects?.(objects);
        return null;
      }
      case "proposed_action": {
        proposedAction = typia.assert<ProposedActionData>(raw).proposed_action;
        if (proposedAction) handlers.onProposedAction?.(proposedAction);
        return null;
      }
      case "suggestions": {
        suggestions = typia.assert<SuggestionsData>(raw).suggestions;
        handlers.onSuggestions?.(suggestions);
        return null;
      }
      case "done": {
        const data = typia.assert<DoneData>(raw);
        return {
          reply: data.reply,
          // Fall back to the proposed action accumulated mid-stream (the `proposed_action` event),
          // the same way objects/suggestions fall back to their accumulated state. A done frame that
          // omits (or nulls) proposed_action must not erase a confirmation card already shown.
          proposedAction: data.proposed_action ?? proposedAction,
          objects: data.objects ?? objects,
          suggestions: data.suggestions ?? suggestions,
        };
      }
      case "error": {
        throw new ResponseError(typia.assert<ErrorData>(raw).message);
      }
      default:
        return null;
    }
  };

  for (;;) {
    const { value, done: streamDone } = await reader.read();
    if (streamDone) break;
    buffer += decoder.decode(value, { stream: true });
    // Frames are separated by a blank line. Process every complete frame, keep the remainder.
    let separator = buffer.indexOf("\n\n");
    while (separator !== -1) {
      const frame = buffer.slice(0, separator);
      buffer = buffer.slice(separator + 2);
      if (frame.trim().length > 0) done = handleFrame(frame) ?? done;
      separator = buffer.indexOf("\n\n");
    }
  }
  if (buffer.trim().length > 0) done = handleFrame(buffer) ?? done;

  // The controller always ends a successful turn with a `done` event (and surfaces failures as an
  // `error` event, which throws above). If the stream ended without `done`, the connection was
  // truncated mid-turn — surface that as an error instead of accepting a partial/blank reply.
  if (!done) throw new ResponseError();
  return done;
};
