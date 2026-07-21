import { Copy, Share } from "@boxicons/react";
import * as React from "react";

import {
  type AgentStreamHandlers,
  AgentStreamInterruptedError,
  type AgentTurnStatus,
  type ChatMessage,
  type ConversationMessage,
  type DisplayObject,
  type ProposedAction,
  executeAgentAction,
  fetchCustomHtmlProposalPreview,
  fetchAgentTurnStatus,
  fetchLatestAgentConversation,
  isCustomHtmlProposal,
  streamAgentMessage,
} from "$app/data/agent";
import { classNames } from "$app/utils/classNames";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { showAlert } from "$app/components/server-components/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { DefinitionList } from "$app/components/ui/DefinitionList";
import { Textarea } from "$app/components/ui/Textarea";

// While the seller is within this many px of the bottom we keep auto-scrolling as new content
// arrives; if they scroll further up to read earlier messages we leave them there. (Mirrors the
// near-bottom threshold the Communities chat uses.)
const STICK_TO_BOTTOM_THRESHOLD_PX = 200;

// After a stream breaks, how often to ask the server what became of the turn (identified by the
// client-generated turn id sent with the stream request), and how long to keep asking. The server
// tracks the turn's liveness while generating (its model client tolerates up to 120 seconds of
// silence between chunks, across up to 25 tool iterations), so recovery keeps polling as long as
// the server says "in_progress" — a fixed short deadline would abandon turns the server goes on
// to finish. The hard cap only guards against a marker that never resolves.
const TURN_RECOVERY_POLL_INTERVAL_MS = 3000;
const TURN_RECOVERY_MAX_POLLS = 200;
// Consecutive "unknown" statuses tolerated before giving up. Unknown means no stored turn and no
// liveness marker — normally conclusive, but a Redis blip can produce one spuriously, so allow a
// couple of confirming looks.
const TURN_RECOVERY_MAX_CONSECUTIVE_UNKNOWNS = 2;
// Consecutive failed status fetches tolerated before giving up — the same flaky network that
// broke the stream may still be down, so this is more generous than the unknown allowance.
const TURN_RECOVERY_MAX_CONSECUTIVE_FETCH_FAILURES = 10;
// When recovery gives up without a server verdict ("inconclusive"), the stream's connection is
// deliberately left open — the turn may still be generating, and aborting would kill it. These
// pace the background watch that keeps checking the turn's fate (more slowly than recovery)
// purely to release that connection once a verdict makes dropping it safe, so abandoned
// connections don't accumulate for the life of the page.
const ABANDONED_TURN_WATCH_INTERVAL_MS = 15_000;
const ABANDONED_TURN_WATCH_MAX_POLLS = 60;
const ABANDONED_TURN_WATCH_MAX_CONSECUTIVE_UNKNOWNS = 2;

// Cleanup-only watcher for a turn whose recovery ended inconclusively. It never touches the chat
// — adopting a turn this late would race whatever the seller did next — its only job is to abort
// the abandoned stream connection once the server records a verdict ("persisted"/"failed"),
// which is the only evidence that makes the abort safe. When the watch stops WITHOUT a verdict
// (persistent unknowns, or the poll cap with the turn still in progress) it deliberately does
// not abort: "unknown" almost always means the server died — and then its end of the socket is
// already closed, so the browser reclaims the connection without our help — but a server build
// without heartbeat refreshes can look identical while still generating, and an abort would kill
// that turn. The remaining truly-held connection (a turn alive past the cap) is bounded by the
// page's lifetime.
const watchAbandonedTurn = async (clientTurnId: string, streamAbort: AbortController): Promise<void> => {
  let consecutiveUnknowns = 0;
  for (let poll = 0; poll < ABANDONED_TURN_WATCH_MAX_POLLS; poll++) {
    await new Promise((resolve) => setTimeout(resolve, ABANDONED_TURN_WATCH_INTERVAL_MS));
    let turn: AgentTurnStatus;
    try {
      turn = await fetchAgentTurnStatus(clientTurnId);
    } catch {
      // The network may still be down — keep watching until the cap.
      continue;
    }
    switch (turn.status) {
      case "persisted":
      case "failed":
        // Terminal: the turn's outcome is recorded, so dropping the connection can't hurt it.
        streamAbort.abort();
        return;
      case "in_progress":
        consecutiveUnknowns = 0;
        continue;
      case "unknown":
        // No record, no liveness marker: nothing left to wait for — but not a verdict either,
        // so stop watching without aborting (see the comment above).
        consecutiveUnknowns += 1;
        if (consecutiveUnknowns >= ABANDONED_TURN_WATCH_MAX_CONSECUTIVE_UNKNOWNS) return;
        continue;
    }
  }
};

// A UUID v4 for tagging a streamed turn. `crypto.randomUUID` only exists in secure contexts
// (HTTPS or localhost), and the app also runs on plain-HTTP origins (system tests, local dev on
// a custom host) — there we build the UUID from `crypto.getRandomValues`, which has no such
// restriction. The id only has to be unique per turn, not cryptographically meaningful.
const generateTurnId = (): string => {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  const hex = [...bytes]
    .map((byte, index) => {
      if (index === 6) byte = (byte & 0x0f) | 0x40; // version 4
      if (index === 8) byte = (byte & 0x3f) | 0x80; // RFC 4122 variant
      return byte.toString(16).padStart(2, "0");
    })
    .join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
};

type DisplayMessage = ChatMessage & {
  // A proposed change attached to an assistant turn. Once the seller acts on it, we record the
  // outcome so the confirmation card collapses into a status line and can't be triggered twice.
  proposedAction?: ProposedAction;
  actionStatus?: "applied" | "dismissed";
  // Objects the agent looked up or changed this turn, rendered inline as cards beneath the message.
  objects?: DisplayObject[];
};

// Build the renderable chat message for one persisted conversation message. Shared by the
// mount-time hydration and the broken-stream recovery below, so the two paths can't drift on how
// persisted extras (proposed-action card, object cards, applied status) come back to life.
// `staleProposalsDismissed` is their one deliberate difference: a status-less proposal from a
// previous session is stale — its context is gone, so hydration collapses it to dismissed — while
// the same shape recovered moments after a broken stream is this session's live, confirmable card.
const toDisplayMessage = (
  message: ConversationMessage,
  { staleProposalsDismissed }: { staleProposalsDismissed: boolean },
): DisplayMessage => ({
  role: message.role,
  content: message.content,
  ...(message.proposed_action ? { proposedAction: message.proposed_action } : {}),
  ...(message.objects?.length ? { objects: message.objects } : {}),
  ...(message.action_status
    ? { actionStatus: message.action_status }
    : staleProposalsDismissed && message.proposed_action
      ? { actionStatus: "dismissed" as const }
      : {}),
});

type Props = {
  greeting: string;
  suggestions: string[];
};

// One object (product, discount, sale, ...) rendered as a card: a title, an optional subtitle, a
// few key/value rows, and easy copy / open-in-new-tab affordances. Reuses the same Card,
// DefinitionList, and CopyToClipboard primitives used across the dashboard.
const ObjectCard = ({ object }: { object: DisplayObject }) => {
  const copyText = object.copy ?? object.url ?? null;
  return (
    <Card>
      <CardContent className="flex-col items-stretch gap-2">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <strong className="block break-words">{object.title}</strong>
            {object.subtitle ? <span className="break-words text-muted">{object.subtitle}</span> : null}
          </div>
          <div className="flex shrink-0 gap-2">
            {copyText ? (
              <CopyToClipboard text={copyText} copyTooltip="Copy">
                <Button size="icon" aria-label={`Copy ${object.title}`}>
                  <Copy className="size-4" />
                </Button>
              </CopyToClipboard>
            ) : null}
            {object.url ? (
              <NavigationButton
                size="icon"
                aria-label={`Open ${object.title} in a new tab`}
                href={object.url}
                target="_blank"
                rel="noopener noreferrer"
              >
                <Share className="size-4" />
              </NavigationButton>
            ) : null}
          </div>
        </div>
        {object.fields.length > 0 ? (
          <DefinitionList className="text-sm">
            {object.fields.map((field) => (
              <React.Fragment key={field.label}>
                <dt className="text-muted">{field.label}</dt>
                <dd className="break-words">{field.value}</dd>
              </React.Fragment>
            ))}
          </DefinitionList>
        ) : null}
      </CardContent>
    </Card>
  );
};

// A turn's objects: a single card on its own, or a compact list view when the agent returned several.
const ObjectList = ({ objects }: { objects: DisplayObject[] }) =>
  objects.length > 0 ? (
    <div className="flex flex-col gap-2">
      {objects.map((object, index) => (
        <ObjectCard key={`${object.type}-${object.copy ?? object.title}-${index}`} object={object} />
      ))}
    </div>
  ) : null;

// The rendered "what your page will look like" preview state for a custom-HTML proposal card. The
// server computes the resulting page exactly the way confirming would apply it and returns the
// same sandboxed document /landing/embed serves. `enabled: false` (a non-page proposal, or a card
// already acted on) skips the fetch entirely. The state lives here rather than in the preview
// element because the card gates its Confirm button on it: a proposal whose preview hasn't
// rendered — still loading, or invalid (say the page changed under it) — shouldn't be
// confirmable, since the seller would be applying a change they haven't seen (and an invalid one
// would fail anyway).
type CustomHtmlPreviewState =
  | { status: "disabled" }
  | { status: "loading" }
  | { status: "loaded"; html: string }
  | { status: "error"; message: string };

const useCustomHtmlProposalPreview = (action: ProposedAction, enabled: boolean): CustomHtmlPreviewState => {
  const [state, setState] = React.useState<CustomHtmlPreviewState>({ status: enabled ? "loading" : "disabled" });

  // Refetch only when the proposed change itself differs — the surrounding card re-renders with
  // fresh (but identical) action objects as the stream's events land, and each shouldn't re-POST.
  const actionRef = React.useRef(action);
  actionRef.current = action;
  // Mirrors of the current state and previous enabled flag, so the effect below can tell a
  // re-enable (dismissed card's "Review" opened again) apart from a genuine params change without
  // adding them as dependencies.
  const stateRef = React.useRef(state);
  stateRef.current = state;
  const wasEnabledRef = React.useRef(enabled);
  const paramsKey = JSON.stringify(action.params);
  React.useEffect(() => {
    const wasEnabled = wasEnabledRef.current;
    wasEnabledRef.current = enabled;
    if (!enabled) {
      // Keep an already-rendered preview around rather than discarding it: once the seller acts on
      // the card the hook is disabled, but "Review" on the collapsed card should show the exact
      // preview they evaluated. Refetching wouldn't work — an applied edit's find-snippet no
      // longer matches the page — so the loaded snapshot is the only faithful record.
      setState((current) => (current.status === "loaded" ? current : { status: "disabled" }));
      return;
    }
    // Re-enabling with the snapshot still loaded (a dismissed card's "Review" toggled open): the
    // page never changed, so the snapshot is still exact — keep it instead of re-POSTing and
    // risking a transient error wiping what the seller already saw.
    if (!wasEnabled && stateRef.current.status === "loaded") return;
    let cancelled = false;
    setState({ status: "loading" });
    fetchCustomHtmlProposalPreview(actionRef.current)
      .then((html) => {
        if (!cancelled) setState({ status: "loaded", html });
      })
      .catch((e: unknown) => {
        if (!cancelled)
          setState({
            status: "error",
            message: e instanceof Error && e.message ? e.message : "The preview couldn't be loaded.",
          });
      });
    return () => {
      cancelled = true;
    };
  }, [paramsKey, enabled]);

  return state;
};

// Renders the preview state produced by useCustomHtmlProposalPreview. The document renders on an
// opaque origin (no allow-same-origin), just like the live page embed, so the proposed HTML can't
// reach cookies or the dashboard DOM. Unlike the live page's iframe, the sandbox below
// deliberately omits allow-popups-to-escape-sandbox (matching ProfileLandingPagePreview): this
// HTML is a not-yet-confirmed agent proposal shown inside the seller's dashboard, so any popup it
// opens stays sandboxed rather than getting a full unsandboxed window. Popup escape only changes
// popup behavior, not how the page itself renders, so preview fidelity is unaffected.
const CustomHtmlProposalPreview = ({ state }: { state: CustomHtmlPreviewState }) => {
  if (state.status === "disabled") return null;
  if (state.status === "loading")
    return (
      <span className="text-sm text-muted" role="status">
        Loading preview…
      </span>
    );
  if (state.status === "error") return <span className="text-sm text-muted">Preview unavailable: {state.message}</span>;
  return (
    <iframe
      title="Preview of your page after this change"
      srcDoc={state.html}
      sandbox="allow-scripts allow-forms allow-popups"
      referrerPolicy="no-referrer"
      className="h-96 w-full rounded border border-border bg-white"
    />
  );
};

const ProposedActionCard = ({
  action,
  status,
  isPending,
  isApplying,
  onConfirm,
  onDismiss,
}: {
  action: ProposedAction;
  status?: "applied" | "dismissed";
  isPending: boolean;
  isApplying: boolean;
  onConfirm: () => void;
  onDismiss: () => void;
}) => {
  const isHtmlProposal = isCustomHtmlProposal(action);
  // Whether the acted-on compact card is expanded to show what the proposal was. Only meaningful
  // once `status` is set; a fresh proposal always shows its full review surface.
  const [isReviewOpen, setIsReviewOpen] = React.useState(false);
  // Pending cards always fetch/render the preview. Acted-on cards keep the already-loaded snapshot
  // (see the hook) so "Review" re-shows exactly what the seller evaluated. When no snapshot exists
  // (the card was hydrated as already-acted-on), a DISMISSED proposal fetches lazily once "Review"
  // is expanded — a dismissed change never touched the page, so the server can still compute what
  // the seller saw. An APPLIED edit's find-snippet no longer matches the (now changed) page, so it
  // can't be refetched; that case falls back to the one-line summary below.
  const preview = useCustomHtmlProposalPreview(
    action,
    isHtmlProposal && (!status || (status === "dismissed" && isReviewOpen)),
  );
  // A page proposal is only confirmable once its preview has rendered — before that the seller
  // hasn't seen what they'd be applying, and a preview that failed (say, the page changed under
  // the proposal) means confirming would fail the same way. Dismiss stays available throughout.
  const confirmBlockedOnPreview = isHtmlProposal && !status && preview.status !== "loaded";

  const fieldRows =
    action.fields && action.fields.length > 0 ? (
      <DefinitionList className="text-sm">
        {action.fields.map((field) => (
          <React.Fragment key={field.label}>
            <dt className="text-muted">{field.label}</dt>
            <dd className="break-words">{field.value}</dd>
          </React.Fragment>
        ))}
      </DefinitionList>
    ) : (
      <span className="break-words">{action.summary}</span>
    );

  if (status) {
    // Once the seller has acted on the proposal, the full card no longer earns its space in the
    // chat — collapse it to a one-line record of what happened (like the change cards in coding
    // agents), with the details available behind "Review". Custom-HTML proposals re-show the
    // preview snapshot the seller evaluated (kept loaded by the hook above); if it never loaded
    // (say, the card was hydrated as already-acted-on), fall back to the one-line summary.
    return (
      <Card>
        <CardContent className="items-center justify-between gap-3">
          <div className="min-w-0">
            <strong className="block break-words">{action.title ?? "Proposed change"}</strong>
            <span role="status" className={status === "applied" ? "text-sm text-green" : "text-sm text-muted"}>
              {status === "applied" ? "Applied" : "Dismissed"}
            </span>
          </div>
          <Button className="shrink-0" aria-expanded={isReviewOpen} onClick={() => setIsReviewOpen((open) => !open)}>
            {isReviewOpen ? "Hide" : "Review"}
          </Button>
        </CardContent>
        {isReviewOpen ? (
          <CardContent className="flex-col items-stretch gap-2">
            {isHtmlProposal ? (
              preview.status !== "disabled" ? (
                // The kept snapshot (or the lazy dismissed-card fetch, including its loading and
                // error states) — the same rendered surface the seller originally evaluated.
                <CustomHtmlProposalPreview state={preview} />
              ) : (
                // No preview to show — an applied edit hydrated as already-acted-on can't be
                // re-rendered (its find-snippet no longer matches the changed page).
                <span className="break-words">{action.summary}</span>
              )
            ) : (
              fieldRows
            )}
          </CardContent>
        ) : null}
      </Card>
    );
  }

  return (
    // Same solid card treatment as the object cards (Card = rounded border-border + a divider), with the
    // actions in a divided footer — secondary on the left, primary (Confirm) on the right.
    <Card>
      <CardContent className="flex-col items-stretch gap-2">
        <strong>{action.title ?? "Proposed change"}</strong>
        {isHtmlProposal ? (
          // A page edit's fields are literal find/replace HTML — a wall of markup that reads as a
          // glitch, not a preview. The rendered result IS the review surface, so it replaces the
          // raw rows entirely.
          <CustomHtmlProposalPreview state={preview} />
        ) : (
          fieldRows
        )}
      </CardContent>
      <CardContent className="justify-end gap-2">
        <Button disabled={isPending} onClick={onDismiss}>
          Dismiss
        </Button>
        <Button color="accent" disabled={isPending || confirmBlockedOnPreview} onClick={onConfirm}>
          {isApplying ? "Applying…" : "Confirm"}
        </Button>
      </CardContent>
    </Card>
  );
};

export const AgentChat = ({ greeting, suggestions }: Props) => {
  const [messages, setMessages] = React.useState<DisplayMessage[]>([{ role: "assistant", content: greeting }]);
  const [input, setInput] = React.useState("");
  const [isSending, setIsSending] = React.useState(false);
  // The stored conversation this chat belongs to (server-side external id). Set when the latest
  // conversation is resumed on mount or when the first turn's response creates one; sent with each
  // turn so the server appends to the same conversation instead of starting a new one.
  const [conversationId, setConversationId] = React.useState<string | null>(null);
  // Ref mirror of conversationId so in-flight callbacks (the streaming turn resolves after several
  // state updates) always read the current id without re-creating handlers.
  const conversationIdRef = React.useRef<string | null>(null);
  conversationIdRef.current = conversationId;
  // Flips true the moment the seller sends their first message. Guards the mount-time hydration
  // below: once a turn is in flight (which may create a brand-new stored conversation), a late
  // "latest conversation" response must not overwrite the chat or its conversation id — otherwise
  // subsequent turns would be appended to the wrong stored conversation.
  const hasSentMessageRef = React.useRef(false);
  // Whether the assistant reply has started arriving this turn — drives the "Thinking..." bubble,
  // which we show only until the first token lands, then let the streaming text take over.
  const [isStreaming, setIsStreaming] = React.useState(false);
  // "What next" prompts suggested after the latest reply, to keep the conversation going. Cleared
  // when a new turn starts and refreshed from the stream's `suggestions` event.
  const [followUps, setFollowUps] = React.useState<string[]>([]);
  const [pendingActionIndex, setPendingActionIndex] = React.useState<number | null>(null);
  const scrollRef = React.useRef<HTMLDivElement>(null);
  const inputRef = React.useRef<HTMLTextAreaElement>(null);
  // Whether to follow new content to the bottom. Stays true while the seller is near the bottom and
  // flips off if they scroll up to read earlier messages, so streaming/suggestions don't yank them back.
  const stickToBottom = React.useRef(true);

  const handleScroll = () => {
    const el = scrollRef.current;
    if (el) stickToBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < STICK_TO_BOTTOM_THRESHOLD_PX;
  };

  // Keep the latest content pinned to the bottom as the conversation grows (including each streamed
  // token), unless the seller has scrolled up. A direct scrollTop assignment is instant, so the newest
  // line never sits below the fold.
  React.useEffect(() => {
    const el = scrollRef.current;
    if (el && stickToBottom.current) el.scrollTop = el.scrollHeight;
  }, [messages, isSending, followUps]);

  // Keep the composer ready to type: focus on load and again whenever a turn finishes. The textarea
  // is disabled while a reply streams, which drops focus, so re-focus once it re-enables.
  React.useEffect(() => {
    if (!isSending) inputRef.current?.focus({ preventScroll: true });
  }, [isSending]);

  // On mount, resume the most recently active stored conversation (like OpenAI/Claude restore your
  // last chat) so a page refresh doesn't lose the history. Any turn the seller sends before this
  // resolves wins: it starts a fresh conversation, and we skip hydration rather than clobber it.
  React.useEffect(() => {
    let cancelled = false;
    void fetchLatestAgentConversation()
      .then((conversation) => {
        if (cancelled) return;
        if (!conversation || conversation.messages.length === 0 || hasSentMessageRef.current) return;
        setMessages([
          { role: "assistant", content: greeting },
          // A proposal persisted without a status was never confirmed in the session it was made.
          // Its context (and the throttle window) is gone, so render it as dismissed rather than
          // offering a stale, re-confirmable change after reload.
          ...conversation.messages.map((message) => toDisplayMessage(message, { staleProposalsDismissed: true })),
        ]);
        setConversationId(conversation.id);
      })
      .catch(() => {
        // Resuming is best-effort; a failed fetch just means starting a fresh chat.
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // A streamed turn died before its terminal `done` frame. The turn was tagged with a
  // client-generated id when it was sent, so ask the server what became of that EXACT turn —
  // persisted, still generating, failed, or unknown — instead of inferring from the seller's
  // latest conversation (which another tab or device can change at any moment). Polls for as long
  // as the server reports the turn in progress: the server allows long silent stretches between
  // model chunks, so a completed reply can persist well after the stream broke. When the turn is
  // recovered, replaces the partially-rendered assistant message with the persisted one (including
  // its proposed-action card and object cards) and adopts the conversation id.
  //
  // The outcome distinguishes how sure we are, because the caller acts on it twice over:
  //   recovered    -> the persisted turn was adopted; nothing to surface
  //   failed       -> the server's own verdict: this turn will never persist
  //   inconclusive -> recovery gave up (unknowns, fetch failures, poll cap) without a server
  //                   verdict — the turn MAY still be generating
  // For anything but "recovered" the caller falls back to the normal error handling; but only a
  // terminal outcome ("recovered"/"failed") makes it safe to tear down the abandoned stream
  // connection — after "inconclusive", an abort could kill a turn that is still being generated.
  type RecoveryOutcome = "recovered" | "failed" | "inconclusive";
  const recoverInterruptedTurn = async (clientTurnId: string, assistantIndex: number): Promise<RecoveryOutcome> => {
    const adopt = (turn: Extract<AgentTurnStatus, { status: "persisted" }>) => {
      setMessages((prev) => {
        const next = [...prev];
        // Unlike the mount-time hydration (where a status-less proposal is stale and rendered
        // dismissed), this proposal was made moments ago in the live session — keep it
        // confirmable, exactly as it would have been had the stream survived.
        next[assistantIndex] = toDisplayMessage(turn.message, { staleProposalsDismissed: false });
        return next;
      });
      // Adopting the conversation id matters even mid-conversation, but especially on a fresh
      // chat: without it the next turn would silently start a brand-new conversation.
      setConversationId(turn.conversation_id);
    };

    let consecutiveUnknowns = 0;
    let consecutiveFetchFailures = 0;
    for (let poll = 0; poll < TURN_RECOVERY_MAX_POLLS; poll++) {
      if (poll > 0) await new Promise((resolve) => setTimeout(resolve, TURN_RECOVERY_POLL_INTERVAL_MS));
      let turn: AgentTurnStatus;
      try {
        turn = await fetchAgentTurnStatus(clientTurnId);
      } catch {
        // The same flaky network that broke the stream may fail this fetch too — keep trying for
        // a while before concluding anything.
        consecutiveFetchFailures += 1;
        if (consecutiveFetchFailures >= TURN_RECOVERY_MAX_CONSECUTIVE_FETCH_FAILURES) return "inconclusive";
        continue;
      }
      consecutiveFetchFailures = 0;
      switch (turn.status) {
        case "persisted":
          adopt(turn);
          return "recovered";
        case "failed":
          // The server's verdict: this turn errored and will never persist. Stop immediately.
          return "failed";
        case "in_progress":
          // The server is still generating — keep waiting, however long it takes; its own
          // liveness marker (not a client-side deadline) decides when the turn is dead.
          consecutiveUnknowns = 0;
          continue;
        case "unknown":
          // No stored turn and no liveness marker. Normally conclusive, but a Redis blip (or a
          // server build without heartbeat refreshes) can produce it spuriously — so give up on
          // waiting, but don't report it as a server verdict.
          consecutiveUnknowns += 1;
          if (consecutiveUnknowns >= TURN_RECOVERY_MAX_CONSECUTIVE_UNKNOWNS) return "inconclusive";
          continue;
      }
    }
    return "inconclusive";
  };

  const send = async (text: string) => {
    const trimmed = text.trim();
    if (trimmed.length === 0 || isSending) return;

    // From here on the seller owns the chat: block the mount-time hydration from replacing it.
    hasSentMessageRef.current = true;

    // Sending re-engages auto-scroll so the seller's own message and the reply come into view.
    stickToBottom.current = true;

    // Only the plain role/content pairs go to the server; UI-only fields stay local.
    const history: ChatMessage[] = [...messages, { role: "user", content: trimmed }].map(({ role, content }) => ({
      role,
      content,
    }));
    // The index the streamed assistant reply will occupy: right after the user message we add.
    const assistantIndex = messages.length + 1;
    // Tag the turn with a unique id before sending so, if the stream breaks, recovery can ask the
    // server about this exact turn instead of guessing from the seller's latest conversation.
    const clientTurnId = generateTurnId();
    setMessages((prev) => [...prev, { role: "user", content: trimmed }]);
    setInput("");
    setFollowUps([]);
    setIsSending(true);
    setIsStreaming(false);

    // Append text to the streaming assistant message, creating it on the first token so the bubble
    // appears exactly when content starts arriving.
    const appendToken = (chunk: string) =>
      setMessages((prev) => {
        const next = [...prev];
        const existing = next[assistantIndex];
        if (existing && existing.role === "assistant") {
          next[assistantIndex] = { ...existing, content: existing.content + chunk };
        } else {
          next[assistantIndex] = { role: "assistant", content: chunk };
        }
        return next;
      });

    // Merge a patch into the assistant message at assistantIndex, creating it if no token has
    // arrived yet. This is what lets a tokenless turn (e.g. the model stages a write and returns an
    // empty final reply) still render its proposed-action card / object cards.
    const upsertAssistant = (patch: Partial<DisplayMessage>) =>
      setMessages((prev) => {
        const next = [...prev];
        const existing = next[assistantIndex];
        const base: DisplayMessage =
          existing && existing.role === "assistant" ? existing : { role: "assistant", content: "" };
        next[assistantIndex] = { ...base, ...patch };
        return next;
      });

    // Handle for tearing down the stream's connection once the turn's fate is known. It matters
    // for the stalled-connection case: the stream's inactivity timeout abandons (rather than
    // cancels) a read that will never resolve, leaving the connection held open — abandoning is
    // deliberate, since cancelling a connection the server is still writing to would abort and
    // fail a healthy turn. The abort below fires only on a terminal outcome (the stream resolved
    // or errored, or recovery reached a server verdict); after an inconclusive recovery the
    // connection is left alone, because the server may still be generating on it.
    const streamAbort = new AbortController();
    let turnSettled = false;

    const handlers: AgentStreamHandlers = {
      onToken: (chunk) => {
        setIsStreaming(true);
        appendToken(chunk);
      },
      onReset: () => {
        // An intermediate tool-use turn streamed preamble text; clear it so the real reply replaces
        // it instead of appending to it.
        setMessages((prev) =>
          prev.map((msg, i) => (i === assistantIndex && msg.role === "assistant" ? { ...msg, content: "" } : msg)),
        );
      },
      onObjects: (objects) => upsertAssistant({ objects }),
      onProposedAction: (proposedAction) => upsertAssistant({ proposedAction }),
      onSuggestions: (next) => setFollowUps(next),
    };

    try {
      const result = await streamAgentMessage(
        history,
        handlers,
        conversationIdRef.current,
        clientTurnId,
        streamAbort.signal,
      );
      turnSettled = true;
      if (result.conversationId) setConversationId(result.conversationId);
      // Reconcile with the final assembled turn. Upsert (not map) so a turn that produced no token —
      // e.g. the model staged a write and returned an empty reply — still lands its card/objects.
      setMessages((prev) => {
        const next = [...prev];
        const existing = next[assistantIndex];
        const prior: DisplayMessage =
          existing && existing.role === "assistant" ? existing : { role: "assistant", content: "" };
        next[assistantIndex] = {
          role: "assistant",
          content: result.reply || prior.content || "",
          ...(result.proposedAction ? { proposedAction: result.proposedAction } : {}),
          ...(result.objects.length > 0 ? { objects: result.objects } : {}),
        };
        return next;
      });
      setFollowUps(result.suggestions);
    } catch (e) {
      // A broken stream usually means the server finished (or is still finishing) the turn
      // without noticing the client stopped receiving — so the truncated text on screen
      // misrepresents a reply that exists (or will exist) in full server-side. Recover this exact
      // turn by its id before treating this as a failure. Server-reported errors (`error` events)
      // skip this: those turns were never saved, and the server already closed the stream, so the
      // turn counts as settled.
      let recovered = false;
      if (e instanceof AgentStreamInterruptedError) {
        const outcome = await recoverInterruptedTurn(clientTurnId, assistantIndex);
        recovered = outcome === "recovered";
        turnSettled = outcome !== "inconclusive";
        // Recovery couldn't tell what became of the turn, so the `finally` below leaves its
        // connection open (aborting could kill a turn still being generated). Hand the cleanup to
        // the background watch, which releases the connection once the turn's fate is known.
        if (!turnSettled) void watchAbandonedTurn(clientTurnId, streamAbort);
      } else {
        turnSettled = true;
      }
      if (!recovered) {
        showAlert(e instanceof Error && e.message ? e.message : "Something went wrong. Please try again.", "error");
        setMessages((prev) => {
          const next = [...prev];
          // If nothing streamed, drop in a friendly fallback; otherwise keep what arrived.
          if (!next[assistantIndex] || next[assistantIndex]?.role !== "assistant") {
            next[assistantIndex] = { role: "assistant", content: "Sorry, I ran into a problem. Please try again." };
          }
          return next;
        });
      }
    } finally {
      // Tear down whatever the stall timeout abandoned only when the turn's fate is known —
      // completed, recovered, or a server "failed" verdict. On a cleanly finished stream this is
      // a no-op; on a stalled one it releases the held connection. After an inconclusive recovery
      // the connection is deliberately left open: the server may still be generating on it, and
      // an abort would raise ClientDisconnected there and kill a turn that could yet persist —
      // the background watch started above releases it later instead.
      if (turnSettled) streamAbort.abort();
      setIsSending(false);
      setIsStreaming(false);
    }
  };

  const confirmAction = async (index: number, action: ProposedAction) => {
    setPendingActionIndex(index);
    try {
      const { message, object } = await executeAgentAction(action, conversationIdRef.current);
      showAlert(message, "success");
      // Mark the proposal applied and attach the created/edited object so it renders as a card.
      setMessages((prev) =>
        prev.map((msg, i) =>
          i === index ? { ...msg, actionStatus: "applied", ...(object ? { objects: [object] } : {}) } : msg,
        ),
      );
    } catch (e) {
      showAlert(e instanceof Error && e.message ? e.message : "That change couldn't be applied.", "error");
    } finally {
      setPendingActionIndex(null);
    }
  };

  const dismissAction = (index: number) => {
    setMessages((prev) => prev.map((msg, i) => (i === index ? { ...msg, actionStatus: "dismissed" } : msg)));
  };

  const hasText = input.trim().length > 0;

  return (
    <div className="flex h-full flex-col">
      {/* The scroll container spans the full width so its scrollbar sits at the far right; the chat
          content inside stays narrow and centered (max-w-2xl). */}
      <div
        ref={scrollRef}
        onScroll={handleScroll}
        className="flex flex-1 flex-col overflow-y-auto"
        aria-label="Conversation"
        role="log"
      >
        {/* Content starts at the top and grows downward; the effect below keeps the newest line in
            view as the conversation gets long enough to scroll. */}
        <div className="mx-auto flex w-full max-w-2xl flex-col gap-4 p-4 md:p-8">
          {messages.map((message, index) => {
            const isUser = message.role === "user";
            // A pending proposed change reads as the confirmation card alone — suppress the objects the
            // agent looked up this turn (e.g. the whole product list) as noise. The applied result
            // object still shows once the change goes through.
            const showObjects =
              !!message.objects?.length && (!message.proposedAction || message.actionStatus === "applied");
            return (
              <div
                key={index}
                className={isUser ? "flex justify-end" : "flex justify-start"}
                aria-label={isUser ? "You" : "Assistant"}
              >
                <div className={`flex flex-col gap-2 ${isUser ? "max-w-[85%] items-end" : "w-full"}`}>
                  {message.content ? (
                    isUser ? (
                      // Square off the sender-side corner (bottom-right) into a subtle tail.
                      <div className="rounded-2xl rounded-br-md bg-accent px-4 py-2 text-accent-foreground">
                        <p className="break-words whitespace-pre-wrap">{message.content}</p>
                      </div>
                    ) : (
                      // Assistant turns read as plain prose, not chat bubbles.
                      <p className="break-words whitespace-pre-wrap">{message.content}</p>
                    )
                  ) : null}
                  {message.proposedAction ? (
                    <ProposedActionCard
                      action={message.proposedAction}
                      status={message.actionStatus}
                      // Also treat an in-flight turn as pending: while streaming, the proposal card
                      // can render before the terminal `done` event persists the turn server-side.
                      // Confirming in that window would apply the change before the stored proposal
                      // exists, so it could never be marked applied in the saved history.
                      isPending={pendingActionIndex !== null || isSending}
                      isApplying={pendingActionIndex === index}
                      onConfirm={() => message.proposedAction && void confirmAction(index, message.proposedAction)}
                      onDismiss={() => dismissAction(index)}
                    />
                  ) : null}
                  {showObjects ? <ObjectList objects={message.objects ?? []} /> : null}
                </div>
              </div>
            );
          })}
          {isSending && !isStreaming ? (
            <div className="flex items-center gap-2 text-muted" role="status" aria-label="Working on it">
              <span className="size-3 shrink-0 animate-pulse rounded-full border-2 border-accent" aria-hidden="true" />
              <span className="text-sm">Working on it…</span>
            </div>
          ) : null}
          {/* Suggested prompts sit at the end of the conversation (not pinned above the composer) so
              they read as the chat's next step and scroll with it. */}
          {messages.length <= 1 ? (
            <div className="flex flex-wrap gap-2">
              {suggestions.map((suggestion) => (
                <Button key={suggestion} onClick={() => void send(suggestion)} disabled={isSending}>
                  {suggestion}
                </Button>
              ))}
            </div>
          ) : followUps.length > 0 ? (
            <div className="flex flex-wrap gap-2" aria-label="Suggested follow-ups">
              {followUps.map((suggestion) => (
                <Button key={suggestion} onClick={() => void send(suggestion)} disabled={isSending}>
                  {suggestion}
                </Button>
              ))}
            </div>
          ) : null}
        </div>
      </div>

      <div className="mx-auto flex w-full max-w-2xl flex-col gap-4 px-4 pb-4 md:px-8 md:pb-8">
        <form
          className="flex flex-col gap-1 rounded border border-border bg-background p-2 focus-within:outline-2 focus-within:outline-offset-0 focus-within:outline-accent"
          onSubmit={(e) => {
            e.preventDefault();
            void send(input);
          }}
        >
          <Textarea
            ref={inputRef}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                void send(input);
              }
            }}
            placeholder="Ask about your store or describe a change…"
            rows={2}
            aria-label="Message"
            disabled={isSending}
            className="resize-none border-none bg-transparent p-2 focus:outline-none"
          />
          <div className="flex justify-end">
            {/* size-11 (44px) over the icon default (48px): tighter, but still the min touch target. */}
            <Button
              type="submit"
              color={hasText ? "accent" : "filled"}
              size="icon"
              aria-label="Send"
              className={classNames("size-11 rounded-full opacity-100", !hasText && "text-muted")}
              disabled={isSending || !hasText}
            >
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
                <path
                  d="M7 12V2M7 2L2.5 6.5M7 2L11.5 6.5"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            </Button>
          </div>
        </form>
        {/* Promo line for the CLI — hidden on phones where it eats vertical space near the composer. */}
        <small className="hidden flex-wrap items-center justify-center gap-2 text-muted sm:flex">
          <span>Same toolset powers our CLI · Try</span>
          <code className="rounded border border-border px-1.5 py-0.5 font-[inherit]">
            brew install antiwork/cli/gumroad
          </code>
        </small>
      </div>
    </div>
  );
};
