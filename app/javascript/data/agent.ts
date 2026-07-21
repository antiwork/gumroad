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
  | {
      success: true;
      reply: string;
      proposed_action: ProposedAction | null;
      objects?: DisplayObject[];
      conversation_id?: string;
    }
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
  conversationId?: string | null,
): Promise<{
  reply: string;
  proposedAction: ProposedAction | null;
  objects: DisplayObject[];
  conversationId: string | null;
}> => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_agent_messages_path(),
    data: { messages, ...(conversationId ? { conversation_id: conversationId } : {}) },
  });
  const json = typia.assert<SendMessageResponse>(await response.json());
  if (!json.success) throw new ResponseError(json.error);
  return {
    reply: json.reply,
    proposedAction: json.proposed_action,
    objects: json.objects ?? [],
    conversationId: json.conversation_id ?? null,
  };
};

export const executeAgentAction = async (
  action: ProposedAction,
  conversationId?: string | null,
): Promise<{ message: string; object: DisplayObject | null }> => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_agent_actions_path(),
    // The conversation id lets the server mark the stored proposal as applied, so reloaded history
    // shows the collapsed "Applied" card instead of a still-confirmable one.
    data: { type: action.type, params: action.params, ...(conversationId ? { conversation_id: conversationId } : {}) },
  });
  const json = typia.assert<ExecuteActionResponse>(await response.json());
  if (!json.success) throw new ResponseError(json.message);
  return { message: json.message, object: json.object ?? null };
};

// The write endpoints whose proposal cards show a rendered page preview: their body params are
// literal HTML (a find/replace pair, or the whole page), so the generic label/value rows would
// render a wall of markup.
const CUSTOM_HTML_PROPOSAL_ENDPOINTS = ["edit_user_custom_html", "update_user_custom_html"];

// The catalog endpoint id a proposed api_write targets (the server stages proposals as
// { endpoint, path_params, params }), or null when the payload doesn't carry one.
export const proposedActionEndpoint = (action: ProposedAction): string | null =>
  typeof action.params.endpoint === "string" ? action.params.endpoint : null;

export const isCustomHtmlProposal = (action: ProposedAction): boolean => {
  const endpoint = proposedActionEndpoint(action);
  return endpoint !== null && CUSTOM_HTML_PROPOSAL_ENDPOINTS.includes(endpoint);
};

type CustomHtmlPreviewResponse = { success: true; html: string } | { success: false; error: string };

// Fetch the sandboxed document showing the seller's page as it would look after the proposed
// custom-HTML change, for the confirmation card's preview iframe. The server computes the change
// the same way confirming would apply it, so the preview and the eventual result can't disagree.
export const fetchCustomHtmlProposalPreview = async (action: ProposedAction): Promise<string> => {
  const body = action.params.params;
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_agent_custom_html_preview_path(),
    data: {
      endpoint: proposedActionEndpoint(action),
      ...(typeof body === "object" && body !== null ? body : {}),
    },
  });
  const json = typia.assert<CustomHtmlPreviewResponse>(await response.json());
  if (!json.success) throw new ResponseError(json.error);
  return json.html;
};

// One persisted message of a stored conversation, as returned by the conversations endpoint. The
// server keeps each turn's structured extras (proposed-action card, object cards, applied status)
// so the chat re-renders history exactly as it looked live.
export type ConversationMessage = {
  role: ChatRole;
  content: string;
  proposed_action?: ProposedAction | null;
  objects?: DisplayObject[] | null;
  action_status?: "applied" | "dismissed" | null;
};

export type Conversation = {
  id: string;
  title: string | null;
  messages: ConversationMessage[];
};

type LatestConversationResponse = { success: true; conversation: Conversation | null };

// Fetch the seller's most recently active conversation so the Agent tab can resume it on mount —
// the way hosted chat products restore your last chat. Resolves null when there's nothing to resume.
export const fetchLatestAgentConversation = async (): Promise<Conversation | null> => {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.internal_agent_conversations_latest_path(),
  });
  if (!response.ok) throw new ResponseError();
  const json = typia.assert<LatestConversationResponse>(await response.json());
  return json.conversation;
};

// What the server knows about one streamed turn, identified by the client-generated id sent with
// the stream request. Used to recover a turn whose SSE connection broke: `persisted` carries the
// stored assistant message and the conversation it landed in; `in_progress` means the server is
// still generating it (keep polling); `failed` means it errored and will never persist;
// `unknown` means there's no record and no liveness marker (waiting longer won't help).
export type AgentTurnStatus =
  | { status: "persisted"; conversation_id: string; message: ConversationMessage }
  | { status: "in_progress" | "failed" | "unknown" };

type AgentTurnStatusResponse =
  | { success: true; status: "persisted"; conversation_id: string; message: ConversationMessage }
  | { success: true; status: "in_progress" | "failed" | "unknown" }
  | { success: false; error: string };

export const fetchAgentTurnStatus = async (clientTurnId: string): Promise<AgentTurnStatus> => {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.internal_agent_turn_status_path(clientTurnId),
  });
  if (!response.ok) throw new ResponseError();
  const json = typia.assert<AgentTurnStatusResponse>(await response.json());
  if (!json.success) throw new ResponseError(json.error);
  return json.status === "persisted"
    ? { status: json.status, conversation_id: json.conversation_id, message: json.message }
    : { status: json.status };
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
  // The id of the stored conversation this turn was persisted to; send it on the next turn (and on
  // action confirmation) so the server appends instead of starting a new conversation.
  conversationId: string | null;
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
  conversation_id?: string;
};

// How long to wait for the next stream bytes before treating the connection as dead. The server
// commits the response immediately and writes a keepalive comment every 15 seconds for as long as
// the turn is being generated (real events can be minutes apart on tool-heavy turns), so a
// healthy connection is never silent anywhere near this long. The value also stays above the
// 120 seconds of model silence the server itself tolerates between chunks, which keeps the
// timeout safe even against a server build that predates the heartbeats (deploy skew). Erring
// high is cheap anyway: a timeout that fires on a turn the server is in fact still generating
// lands in the same turn-status recovery, which keeps waiting while the server reports it in
// progress.
const STREAM_INACTIVITY_TIMEOUT_MS = 130_000;

// Thrown when the stream dies before its terminal `done` frame — the connection dropped, a
// frame arrived mangled, or the connection went silent past the inactivity timeout — as opposed
// to the server explicitly reporting a failure via an `error`
// event. The distinction matters to the caller: when the transport breaks, the server usually
// never notices and finishes the turn anyway (its remaining writes land in dead socket buffers),
// so the complete reply exists in the stored conversation and the caller can recover it from
// there instead of leaving the partially-streamed text on screen as if it were the whole reply.
export class AgentStreamInterruptedError extends ResponseError {}

// Stream one conversation turn over Server-Sent Events. Calls the handlers as events arrive and
// resolves with the fully-assembled turn once the `done` event lands. Falls back to throwing a
// ResponseError (so the caller can show the same alert as the non-streaming path) on an `error`
// event, or an AgentStreamInterruptedError when the stream breaks without one.
// `clientTurnId` (a caller-generated UUID) tags the turn server-side so that, after an
// interruption, the caller can recover this exact turn via fetchAgentTurnStatus instead of
// guessing from the seller's latest conversation.
// `abortSignal` lets the caller tear down the underlying connection once the turn has settled.
// It exists for the stalled-connection case: the inactivity timeout below abandons (rather than
// cancels) a pending read, so without an abort the connection would be held open indefinitely.
// The caller should abort only AFTER the turn reaches a terminal state — the stream resolved,
// errored, or turn-status recovery finished — never while the server may still be generating
// (aborting then raises ClientDisconnected server-side, which aborts and fails the turn).
export const streamAgentMessage = async (
  messages: ChatMessage[],
  handlers: AgentStreamHandlers = {},
  conversationId?: string | null,
  clientTurnId?: string | null,
  abortSignal?: AbortSignal,
): Promise<StreamResult> => {
  // Guards every await on the connection — the initial fetch below and each body read later.
  // Neither resolves on its own when the connection silently dies: a fetch awaiting response
  // headers (the server holds them until its first stream write) and a read awaiting more bytes
  // can both sit pending forever (observed locally: the server logs the request complete, the
  // trailing frames never surface, and nothing settles — leaving the composer locked with no
  // error to recover from). The race turns that silence into an interruption, which sends the
  // caller into turn-status recovery instead of hanging.
  //
  // When the clock wins, the pending promise is abandoned rather than cancelled — deliberately.
  // Cancelling tears the connection down, and if the server is in fact still generating, its next
  // write raises ClientDisconnected, aborting the turn and marking it failed — a slow-but-healthy
  // turn would be lost for good. Abandoned, a healthy server finishes and persists the turn, and
  // recovery adopts it. Releasing the connection is then the caller's job, via `abortSignal`,
  // once the turn has settled (see the function comment above).
  const withInactivityTimeout = async <T>(promise: Promise<T>): Promise<T> => {
    let timeoutId: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timeoutId = setTimeout(() => reject(new AgentStreamInterruptedError()), STREAM_INACTIVITY_TIMEOUT_MS);
    });
    try {
      return await Promise.race([promise, timeout]);
    } catch (e) {
      // An abandoned promise can still settle later — typically rejecting when the caller aborts
      // the connection after recovery. Nothing is waiting on it anymore, so swallow that rejection
      // rather than letting it surface as an unhandled promise rejection.
      promise.catch(() => {});
      throw e;
    } finally {
      clearTimeout(timeoutId);
    }
  };

  const response = await withInactivityTimeout(
    request({
      method: "POST",
      accept: "json",
      url: Routes.internal_agent_messages_stream_path(),
      abortSignal,
      data: {
        messages,
        ...(conversationId ? { conversation_id: conversationId } : {}),
        ...(clientTurnId ? { client_turn_id: clientTurnId } : {}),
      },
    }),
  );

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
          conversationId: data.conversation_id ?? conversationId ?? null,
        };
      }
      case "error": {
        throw new ResponseError(typia.assert<ErrorData>(raw).message);
      }
      default:
        return null;
    }
  };

  try {
    for (;;) {
      const { value, done: streamDone } = await withInactivityTimeout(reader.read());
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
      // `done` is the terminal frame — the server writes nothing meaningful after it. Return the
      // assembled turn now rather than draining to EOF, so a connection whose close never reaches
      // the client can't hold a finished turn hostage until the inactivity timeout.
      if (done) return done;
    }
    if (buffer.trim().length > 0) done = handleFrame(buffer) ?? done;
  } catch (e) {
    // An unclean close AFTER the terminal `done` frame (a reset while draining trailing bytes, a
    // mangled keepalive fragment) doesn't invalidate the turn — the assembled result is already in
    // hand, so return it rather than discarding a successful turn as an interruption.
    if (done) return done;
    // An `error` event thrown by handleFrame is the server's own verdict on the turn — pass it
    // through untouched. Anything else (the read rejecting on a dropped connection, unparseable
    // JSON, a frame failing validation) means the transport broke mid-turn, which the caller must
    // be able to tell apart because the turn itself likely completed server-side.
    if (e instanceof ResponseError) throw e;
    throw new AgentStreamInterruptedError();
  }

  // The controller always ends a successful turn with a `done` event (and surfaces failures as an
  // `error` event, which throws above). If the stream ended without `done`, the connection was
  // truncated mid-turn — surface that as an interruption instead of accepting a partial/blank reply.
  if (!done) throw new AgentStreamInterruptedError();
  return done;
};
