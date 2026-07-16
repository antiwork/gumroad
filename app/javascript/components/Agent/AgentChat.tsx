import { Copy, Share } from "@boxicons/react";
import * as React from "react";

import {
  type AgentStreamHandlers,
  AgentStreamInterruptedError,
  type ChatMessage,
  type Conversation,
  type ConversationMessage,
  type DisplayObject,
  type ProposedAction,
  executeAgentAction,
  fetchCustomHtmlProposalPreview,
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
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Textarea } from "$app/components/ui/Textarea";

// While the seller is within this many px of the bottom we keep auto-scrolling as new content
// arrives; if they scroll further up to read earlier messages we leave them there. (Mirrors the
// near-bottom threshold the Communities chat uses.)
const STICK_TO_BOTTOM_THRESHOLD_PX = 200;

// After a stream breaks, when to look again for the persisted turn (the first look happens
// immediately). The server persists the turn the moment the reply completes, so the immediate
// look usually wins — but a connection that broke mid-generation leaves the server unaware,
// still generating, until its next socket write. The retries stretch out to cover that window
// rather than polling quickly and giving up.
const STREAM_RECOVERY_RETRY_DELAYS_MS = [3000, 10000];

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

// The rendered "what your page will look like" preview on a custom-HTML proposal card. The server
// computes the resulting page exactly the way confirming would apply it and returns the same
// sandboxed document /landing/embed serves; it renders here on an opaque origin (no
// allow-same-origin), just like the live page embed, so the proposed HTML can't reach cookies or
// the dashboard DOM.
const CustomHtmlProposalPreview = ({ action }: { action: ProposedAction }) => {
  const [state, setState] = React.useState<
    { status: "loading" } | { status: "loaded"; html: string } | { status: "error"; message: string }
  >({ status: "loading" });

  // Refetch only when the proposed change itself differs — the surrounding card re-renders with
  // fresh (but identical) action objects as the stream's events land, and each shouldn't re-POST.
  const actionRef = React.useRef(action);
  actionRef.current = action;
  const paramsKey = JSON.stringify(action.params);
  React.useEffect(() => {
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
  }, [paramsKey]);

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

  return (
    // Same solid card treatment as the object cards (Card = rounded border-border + a divider), with the
    // actions in a divided footer — secondary on the left, primary (Confirm) on the right.
    <Card>
      <CardContent className="flex-col items-stretch gap-2">
        <strong>{action.title ?? "Proposed change"}</strong>
        {isCustomHtmlProposal(action) ? (
          // A page edit's fields are literal find/replace HTML — a wall of markup that reads as a
          // glitch, not a preview. Lead with the rendered result instead, and keep the exact HTML
          // (the safety boundary: precisely what confirming will apply) available but collapsed.
          // Once acted on, the preview no longer reflects anything actionable (and an applied
          // edit's find-snippet no longer matches), so only pending cards render it.
          <>
            {status ? null : <CustomHtmlProposalPreview action={action} />}
            <Details>
              <DetailsToggle className="text-sm text-muted">View raw HTML</DetailsToggle>
              {fieldRows}
            </Details>
          </>
        ) : (
          fieldRows
        )}
      </CardContent>
      <CardContent className="justify-end gap-2">
        {status === "applied" ? (
          <span role="status" className="mr-auto text-green">
            Applied
          </span>
        ) : status === "dismissed" ? (
          <span role="status" className="mr-auto text-muted">
            Dismissed
          </span>
        ) : (
          <>
            <Button disabled={isPending} onClick={onDismiss}>
              Dismiss
            </Button>
            <Button color="accent" disabled={isPending} onClick={onConfirm}>
              {isApplying ? "Applying…" : "Confirm"}
            </Button>
          </>
        )}
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
  // The id of the seller's most recent stored conversation as seen by the mount-time fetch below,
  // recorded even when hydration is skipped (the seller sent a message before it resolved). Used by
  // stream recovery on a fresh chat: a first turn that persisted creates a brand-NEW conversation,
  // so if the "latest" fetch still returns this pre-existing one, this turn was never stored.
  const preexistingConversationIdRef = React.useRef<string | null>(null);
  // Whether the mount-time fetch actually resolved. `preexistingConversationIdRef` being null is
  // ambiguous on its own (no stored conversations vs. the fetch failed / hasn't landed yet);
  // fresh-chat stream recovery only trusts the null when this flag confirms the fetch completed.
  const preexistingConversationKnownRef = React.useRef(false);
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
        // Remember which conversation was already the seller's latest before this chat wrote
        // anything, whether or not we hydrate it — stream recovery uses it to tell "our first turn
        // was persisted as a new conversation" apart from "the latest is still someone else's".
        preexistingConversationIdRef.current = conversation?.id ?? null;
        preexistingConversationKnownRef.current = true;
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

  // A streamed turn died before its terminal `done` frame. Check whether the turn completed
  // server-side anyway, and if so replace the partially-rendered assistant message with the
  // persisted one (including its proposed-action card and object cards). `streamedContent` is the
  // reply text that reached the screen before the break. Returns whether the turn was recovered;
  // when it wasn't (the failure was real and nothing was stored), the caller falls back to the
  // normal error handling.
  const recoverInterruptedTurn = async (
    sentText: string,
    assistantIndex: number,
    streamedContent: string,
  ): Promise<boolean> => {
    // One look at the stored conversation. `false` means the turn may still be persisting (worth
    // another look); "abort" means no amount of waiting can make recovery correct.
    const attempt = async (): Promise<boolean | "abort"> => {
      let conversation: Conversation | null;
      try {
        conversation = await fetchLatestAgentConversation();
      } catch {
        // Best-effort: the same flaky network that broke the stream may fail this fetch too.
        return false;
      }
      if (!conversation) return false;
      if (conversationIdRef.current) {
        // Only reconcile against the conversation this chat is appending to. A different latest
        // conversation (another tab or device took over) can't become ours by waiting — stop.
        if (conversation.id !== conversationIdRef.current) return "abort";
      } else {
        // Fresh chat: this turn has no conversation id yet, so a persisted first turn lives in a
        // brand-new conversation the server just created. Accept the fetched conversation only
        // when we know it is NOT one that already existed before this chat sent anything —
        // otherwise another tab appending the same prompt text to an older conversation would be
        // mistaken for our turn, and this chat would adopt that conversation's id and append all
        // future turns to the wrong transcript. When the mount-time fetch hasn't resolved we
        // can't make that call yet, so decline this look rather than risk hijacking.
        if (!preexistingConversationKnownRef.current) return false;
        if (preexistingConversationIdRef.current !== null && conversation.id === preexistingConversationIdRef.current)
          return false;
        // Correlate by shape too: the interrupted first turn would have been persisted as a
        // brand-new conversation holding exactly this one turn (the message we sent + the reply).
        // A longer conversation is some existing chat, not this turn.
        if (conversation.messages.length !== 2) return false;
      }
      const persisted = conversation.messages;
      const reply = persisted[persisted.length - 1];
      const userTurn = persisted[persisted.length - 2];
      // Recover only when the stored tail is exactly this turn: the message we just sent followed
      // by an assistant reply. Anything else means this turn hasn't been persisted (yet).
      if (!reply || reply.role !== "assistant" || userTurn?.role !== "user" || userTurn.content !== sentText)
        return false;
      // ...and only when the stored reply extends the text the seller actually watched stream in.
      // An earlier turn in this conversation could have used identical text (a repeated "yes"),
      // and adopting its reply would silently rewrite this failed turn as that old one. Preamble
      // that a reset event cleared never lingers in streamedContent (the tracker resets with it).
      if (streamedContent.trim().length > 0 && !reply.content.startsWith(streamedContent.trim())) return false;
      setMessages((prev) => {
        const next = [...prev];
        // Unlike the mount-time hydration (where a status-less proposal is stale and rendered
        // dismissed), this proposal was made moments ago in the live session — keep it
        // confirmable, exactly as it would have been had the stream survived.
        next[assistantIndex] = toDisplayMessage(reply, { staleProposalsDismissed: false });
        return next;
      });
      setConversationId(conversation.id);
      return true;
    };

    let result = await attempt();
    for (const delayMs of STREAM_RECOVERY_RETRY_DELAYS_MS) {
      if (result !== false) break;
      await new Promise((resolve) => setTimeout(resolve, delayMs));
      result = await attempt();
    }
    return result === true;
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

    // The reply text that has reached the screen this turn, mirrored outside React state so the
    // recovery path can compare it against a persisted reply without reading component state.
    let streamedContent = "";

    const handlers: AgentStreamHandlers = {
      onToken: (chunk) => {
        streamedContent += chunk;
        setIsStreaming(true);
        appendToken(chunk);
      },
      onReset: () => {
        // An intermediate tool-use turn streamed preamble text; clear it so the real reply replaces
        // it instead of appending to it.
        streamedContent = "";
        setMessages((prev) =>
          prev.map((msg, i) => (i === assistantIndex && msg.role === "assistant" ? { ...msg, content: "" } : msg)),
        );
      },
      onObjects: (objects) => upsertAssistant({ objects }),
      onProposedAction: (proposedAction) => upsertAssistant({ proposedAction }),
      onSuggestions: (next) => setFollowUps(next),
    };

    try {
      const result = await streamAgentMessage(history, handlers, conversationIdRef.current);
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
      // A broken stream usually means the server finished and persisted the turn without noticing
      // the client stopped receiving — so the truncated text on screen misrepresents a reply that
      // exists in full server-side. Reconcile with the stored conversation before treating this as
      // a failure. Server-reported errors (`error` events) skip this: those turns were never saved.
      const recovered =
        e instanceof AgentStreamInterruptedError &&
        (await recoverInterruptedTurn(trimmed, assistantIndex, streamedContent));
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
