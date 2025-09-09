import type { Message } from "@helperai/client";
import { useConversation, useRealtimeEvents, useCreateMessage, MessageContent } from "@helperai/react";
import cx from "classnames";
import pinkIcon from "images/pink-icon.png";
import startCase from "lodash/startCase";
import React from "react";

import FileUtils from "$app/utils/file";

import { Button } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDomains } from "$app/components/DomainSettings";
import { FileRowContent } from "$app/components/FileRowContent";
import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";

function MessageListItem({ message, isLastMessage }: { message: Message; isLastMessage: boolean }) {
  const [isExpanded, setIsExpanded] = React.useState(isLastMessage);
  const currentSeller = useCurrentSeller();
  const attachments = [...message.publicAttachments, ...message.privateAttachments];
  const image = message.role === "user" ? (currentSeller?.avatarUrl ?? pinkIcon) : pinkIcon;
  return (
    <div role="listitem" className="!items-stretch !gap-0 !p-0">
      <div
        className="content peer cursor-pointer p-4 hover:bg-[var(--active-bg)] peer-hover:bg-[var(--active-bg)]"
        onClick={() => setIsExpanded((v) => !v)}
      >
        <img className={cx("user-avatar !w-9", image === pinkIcon ? "!border-none" : "")} src={image} />
        <div className={`font-bold ${isExpanded ? "flex-1" : ""}`}>
          {message.role === "user" ? (currentSeller?.name ?? "You") : message.staffName || startCase(message.role)}
        </div>
        <div className={isExpanded ? "hidden" : "ml-2 line-clamp-1 min-w-0 flex-1"}>
          <MessageContent message={message} />
        </div>
        <div className="whitespace-nowrap text-right">
          {new Date(message.createdAt).toLocaleDateString(undefined, { month: "short", day: "numeric" })}
        </div>
      </div>
      <div
        className="actions peer cursor-pointer p-4 pl-0 hover:bg-[var(--active-bg)] peer-hover:bg-[var(--active-bg)]"
        onClick={() => setIsExpanded((v) => !v)}
      >
        <Button outline aria-expanded={isExpanded} aria-label={isExpanded ? "Collapse message" : "Expand message"}>
          {isExpanded ? <Icon name="outline-cheveron-up" /> : <Icon name="outline-cheveron-down" />}
        </Button>
      </div>
      {isExpanded ? (
        <div className="relative col-span-full cursor-default p-4 pl-16">
          <MessageContent message={message} />
          {attachments.length > 0 ? (
            <div role="list" className="rows mt-4 w-full max-w-[500px]">
              {attachments.map((attachment) => (
                <div
                  role="listitem"
                  className={attachment.contentType?.startsWith("image/") ? "!p-0" : ""}
                  key={attachment.url}
                >
                  {attachment.contentType?.startsWith("image/") ? (
                    <img src={attachment.url} alt={attachment.name ?? "Attachment"} className="w-full rounded-sm" />
                  ) : (
                    <FileRowContent
                      name={FileUtils.getFileNameWithoutExtension(attachment.name ?? "Attachment")}
                      extension={FileUtils.getFileExtension(attachment.name ?? "Attachment").toUpperCase()}
                      externalLinkUrl={null}
                      isUploading={false}
                      details={<li>{attachment.contentType?.split("/")[1]}</li>}
                    />
                  )}
                </div>
              ))}
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

export function ConversationDetail({ conversationSlug, onBack }: { conversationSlug: string; onBack: () => void }) {
  const { apiDomain } = useDomains();
  const { data: conversation, isLoading, error, refetch } = useConversation(conversationSlug);
  const { mutateAsync: createMessage, isPending: isSubmitting } = useCreateMessage({
    onError: (error) => {
      showAlert(error.message, "error");
    },
  });

  useRealtimeEvents(conversation?.slug ?? "", { enabled: Boolean(conversation?.slug) });

  const [input, setInput] = React.useState("");
  const [attachments, setAttachments] = React.useState<File[]>([]);
  const fileInputRef = React.useRef<HTMLInputElement | null>(null);

  const handleSubmit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const trimmed = input.trim();
    if (!trimmed) return;
    await createMessage({
      conversationSlug,
      content: trimmed,
      attachments,
      customerInfoUrl: Routes.user_info_api_internal_helper_users_url({ host: apiDomain }),
    });
    setInput("");
    setAttachments([]);
    void refetch();
  };

  if (isLoading) return null;
  if (error || !conversation) return <div>Something went wrong.</div>;

  return (
    <main>
      <header className="!gap-0">
        <a className="no-underline" onClick={onBack}>
          <Icon name="arrow-left" /> Go back to Support tickets
        </a>
        <h1>{conversation.subject}</h1>
      </header>

      <div>
        <div role="list" className="rows mb-12 overflow-hidden" aria-label="Messages">
          {conversation.messages.map((message, index) => (
            <MessageListItem
              key={message.id}
              message={message}
              isLastMessage={index === conversation.messages.length - 1}
            />
          ))}
        </div>

        <form className="mt-4 flex flex-col gap-2" onSubmit={(e) => void handleSubmit(e)}>
          <label htmlFor="reply">Reply</label>
          <textarea
            className="mb-2 flex-1 rounded border px-3 py-2"
            placeholder="Write a reply"
            id="reply"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            rows={5}
          />
          <input
            ref={fileInputRef}
            type="file"
            multiple
            onChange={(e) => {
              const files = Array.from(e.target.files ?? []);
              if (files.length === 0) return;
              setAttachments((prev) => [...prev, ...files]);
              e.currentTarget.value = "";
            }}
          />
          {attachments.length > 0 ? (
            <div role="list" className="rows mb-2" aria-label="Files">
              {attachments.map((file, index) => (
                <div role="listitem" key={`${file.name}-${index}`}>
                  <div className="content">
                    <FileRowContent
                      name={FileUtils.getFileNameWithoutExtension(file.name)}
                      extension={FileUtils.getFileExtension(file.name).toUpperCase()}
                      externalLinkUrl={null}
                      isUploading={false}
                      details={<li>{FileUtils.getReadableFileSize(file.size)}</li>}
                    />
                  </div>
                  <div className="actions">
                    <Button
                      outline
                      color="danger"
                      aria-label="Remove"
                      onClick={() => setAttachments((prev) => prev.filter((_, i) => i !== index))}
                    >
                      <Icon name="trash2" />
                    </Button>
                  </div>
                </div>
              ))}
            </div>
          ) : null}
          <div className="flex gap-2">
            <Button onClick={() => fileInputRef.current?.click()} disabled={isSubmitting}>
              <Icon name="paperclip" /> Attach files
            </Button>
            <Button type="submit" color="primary" disabled={isSubmitting || !input.trim()}>
              {isSubmitting ? "Sending..." : "Send reply"}
            </Button>
          </div>
        </form>
      </div>
    </main>
  );
}
