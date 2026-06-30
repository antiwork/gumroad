import { Copy, Share } from "@boxicons/react";
import * as React from "react";

import {
  type AgentStreamHandlers,
  type ChatMessage,
  type DisplayObject,
  type ProposedAction,
  executeAgentAction,
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

type DisplayMessage = ChatMessage & {
  // A proposed change attached to an assistant turn. Once the seller acts on it, we record the
  // outcome so the confirmation card collapses into a status line and can't be triggered twice.
  proposedAction?: ProposedAction;
  actionStatus?: "applied" | "dismissed";
  // Objects the agent looked up or changed this turn, rendered inline as cards beneath the message.
  objects?: DisplayObject[];
};

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
}) => (
  <div className="flex flex-col gap-2 rounded-2xl border border-dashed p-4">
    <strong>Proposed change</strong>
    <span className="break-words">{action.summary}</span>
    {status === "applied" ? (
      <span role="status" className="text-green">
        Applied
      </span>
    ) : status === "dismissed" ? (
      <span role="status" className="text-muted">
        Dismissed
      </span>
    ) : (
      <div className="flex gap-2">
        <Button color="accent" disabled={isPending} onClick={onConfirm}>
          {isApplying ? "Applying…" : "Confirm"}
        </Button>
        <Button disabled={isPending} onClick={onDismiss}>
          Dismiss
        </Button>
      </div>
    )}
  </div>
);

export const AgentChat = ({ greeting, suggestions }: Props) => {
  const [messages, setMessages] = React.useState<DisplayMessage[]>([{ role: "assistant", content: greeting }]);
  const [input, setInput] = React.useState("");
  const [isSending, setIsSending] = React.useState(false);
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

  const send = async (text: string) => {
    const trimmed = text.trim();
    if (trimmed.length === 0 || isSending) return;

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

    const handlers: AgentStreamHandlers = {
      onToken: (chunk) => {
        setIsStreaming(true);
        appendToken(chunk);
      },
      onReset: () =>
        // An intermediate tool-use turn streamed preamble text; clear it so the real reply replaces
        // it instead of appending to it.
        setMessages((prev) =>
          prev.map((msg, i) => (i === assistantIndex && msg.role === "assistant" ? { ...msg, content: "" } : msg)),
        ),
      onObjects: (objects) => upsertAssistant({ objects }),
      onProposedAction: (proposedAction) => upsertAssistant({ proposedAction }),
      onSuggestions: (next) => setFollowUps(next),
    };

    try {
      const result = await streamAgentMessage(history, handlers);
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
      showAlert(e instanceof Error && e.message ? e.message : "Something went wrong. Please try again.", "error");
      setMessages((prev) => {
        const next = [...prev];
        // If nothing streamed, drop in a friendly fallback; otherwise keep what arrived.
        if (!next[assistantIndex] || next[assistantIndex]?.role !== "assistant") {
          next[assistantIndex] = { role: "assistant", content: "Sorry, I ran into a problem. Please try again." };
        }
        return next;
      });
    } finally {
      setIsSending(false);
      setIsStreaming(false);
    }
  };

  const confirmAction = async (index: number, action: ProposedAction) => {
    setPendingActionIndex(index);
    try {
      const { message, object } = await executeAgentAction(action);
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
        {/* mt-auto fills the chat from the bottom (like a messenger): a short conversation sits just
            above the composer, and the margin collapses once the content is tall enough to scroll. */}
        <div className="mx-auto mt-auto flex w-full max-w-2xl flex-col gap-4 p-4 md:p-8">
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
                      isPending={pendingActionIndex !== null}
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
            <Button
              type="submit"
              color={hasText ? "accent" : "filled"}
              size="icon"
              aria-label="Send"
              className={classNames("size-10 rounded-full opacity-100", !hasText && "text-muted")}
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
        <small className="flex flex-wrap items-center justify-center gap-2 text-muted">
          <span>Same toolset powers our CLI · Try</span>
          <code className="rounded border border-border px-1.5 py-0.5 font-[inherit]">
            brew install antiwork/cli/gumroad
          </code>
        </small>
      </div>
    </div>
  );
};
