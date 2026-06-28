import * as React from "react";

import { type ChatMessage, type ProposedAction, executeAgentAction, sendAgentMessage } from "$app/data/agent";

import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Textarea } from "$app/components/ui/Textarea";

type DisplayMessage = ChatMessage & {
  // A proposed change attached to an assistant turn. Once the seller acts on it, we record the
  // outcome so the confirmation card collapses into a status line and can't be triggered twice.
  proposedAction?: ProposedAction;
  actionStatus?: "applied" | "dismissed";
};

type Props = {
  greeting: string;
  suggestions: string[];
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
          {isApplying ? "Applying..." : "Confirm"}
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
  const [pendingActionIndex, setPendingActionIndex] = React.useState<number | null>(null);
  const scrollRef = React.useRef<HTMLDivElement>(null);

  React.useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" });
  }, [messages, isSending]);

  const send = async (text: string) => {
    const trimmed = text.trim();
    if (trimmed.length === 0 || isSending) return;

    // Only the plain role/content pairs go to the server; UI-only fields stay local.
    const history: ChatMessage[] = [...messages, { role: "user", content: trimmed }].map(({ role, content }) => ({
      role,
      content,
    }));
    setMessages((prev) => [...prev, { role: "user", content: trimmed }]);
    setInput("");
    setIsSending(true);

    try {
      const { reply, proposedAction } = await sendAgentMessage(history);
      setMessages((prev) => [
        ...prev,
        { role: "assistant", content: reply, ...(proposedAction ? { proposedAction } : {}) },
      ]);
    } catch (e) {
      showAlert(e instanceof Error && e.message ? e.message : "Something went wrong. Please try again.", "error");
      setMessages((prev) => [
        ...prev,
        { role: "assistant", content: "Sorry, I ran into a problem. Please try again." },
      ]);
    } finally {
      setIsSending(false);
    }
  };

  const confirmAction = async (index: number, action: ProposedAction) => {
    setPendingActionIndex(index);
    try {
      const message = await executeAgentAction(action);
      showAlert(message, "success");
      setMessages((prev) => prev.map((msg, i) => (i === index ? { ...msg, actionStatus: "applied" } : msg)));
    } catch (e) {
      showAlert(e instanceof Error && e.message ? e.message : "That change couldn't be applied.", "error");
    } finally {
      setPendingActionIndex(null);
    }
  };

  const dismissAction = (index: number) => {
    setMessages((prev) => prev.map((msg, i) => (i === index ? { ...msg, actionStatus: "dismissed" } : msg)));
  };

  return (
    <div className="mx-auto flex h-full max-w-2xl flex-col gap-4 p-4 md:p-8">
      <div ref={scrollRef} className="flex flex-1 flex-col gap-4 overflow-y-auto" aria-label="Conversation" role="log">
        {messages.map((message, index) => (
          <div
            key={index}
            className={message.role === "user" ? "flex justify-end" : "flex justify-start"}
            aria-label={message.role === "user" ? "You" : "Assistant"}
          >
            <div className="flex max-w-[85%] flex-col gap-2">
              <div
                className={`rounded-2xl px-4 py-2 ${
                  message.role === "user" ? "bg-accent text-accent-foreground" : "bg-filled border"
                }`}
              >
                <p className="whitespace-pre-wrap break-words">{message.content}</p>
              </div>
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
            </div>
          </div>
        ))}
        {isSending ? (
          <div className="flex justify-start" aria-label="Assistant">
            <div className="bg-filled rounded-2xl border px-4 py-2 text-muted">Thinking...</div>
          </div>
        ) : null}
      </div>

      {messages.length <= 1 ? (
        <div className="flex flex-wrap gap-2">
          {suggestions.map((suggestion) => (
            <Button key={suggestion} size="sm" onClick={() => void send(suggestion)} disabled={isSending}>
              {suggestion}
            </Button>
          ))}
        </div>
      ) : null}

      <form
        className="flex items-end gap-2"
        onSubmit={(e) => {
          e.preventDefault();
          void send(input);
        }}
      >
        <Textarea
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              void send(input);
            }
          }}
          placeholder="Ask about your store or describe a change..."
          rows={2}
          aria-label="Message"
          disabled={isSending}
          className="flex-1"
        />
        <Button type="submit" color="accent" className="shrink-0 whitespace-nowrap" disabled={isSending || input.trim().length === 0}>
          Send
        </Button>
      </form>
    </div>
  );
};
