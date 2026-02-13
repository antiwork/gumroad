import { type FormDataErrors } from "@inertiajs/core";
import * as React from "react";

import { MAX_MESSAGE_LENGTH } from "$app/pages/Communities/Index";
import { classNames } from "$app/utils/classNames";

import { CommunityDraft } from "$app/components/Communities/useCommunities";
import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";

type Props = {
  draft: CommunityDraft | null;
  updateDraftMessage: (content: string) => void;
  onSend: () => void;
  onHeightChange: (height: number) => void;
  errors: FormDataErrors<{ community_chat_message: { content: string } }> | undefined;
};

export const ChatMessageInput = React.forwardRef<HTMLTextAreaElement, Props>(
  ({ draft, updateDraftMessage, onSend, onHeightChange, errors }, ref) => {
    const handleSend = React.useCallback(() => {
      if (!draft?.content || draft.content.length === 0) return;
      if (draft.content.length > MAX_MESSAGE_LENGTH) {
        showAlert("Message is too long.", "error");
        return;
      }
      onSend();
    }, [draft?.content, onSend]);

    const adjustTextareaHeight = React.useCallback(() => {
      const textarea = typeof ref === "function" ? null : ref?.current;
      if (!textarea) return;

      const scrollTop = textarea.scrollTop;
      textarea.style.height = "auto";
      const newHeight = Math.min(textarea.scrollHeight, 150);
      textarea.style.height = `${newHeight}px`;
      textarea.scrollTop = scrollTop;

      if (textarea.parentElement) onHeightChange(textarea.parentElement.offsetHeight);
      textarea.focus();
    }, [onHeightChange, ref]);

    React.useEffect(adjustTextareaHeight, [draft?.content, adjustTextareaHeight]);

    return (
      <div
        className={classNames("input pr-2! dark:border-[rgb(var(--parent-color)/var(--border-alpha))]", {
          "!border-red": errors && errors["community_chat_message.content"],
        })}
      >
        <textarea
          ref={ref}
          className="resize-none"
          rows={1}
          placeholder="Type a message"
          value={draft?.content ?? ""}
          disabled={draft?.isSending}
          onChange={(e) => updateDraftMessage(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              handleSend();
            }
          }}
        />
        <button
          className={classNames(
            "hover:rgb(var(--primary)) flex cursor-pointer items-center rounded-md border border-solid bg-black px-2 py-1.5 text-white all-unset dark:bg-[rgb(var(--primary))] dark:text-black",
            {
              "cursor-default opacity-50": !draft?.content.trim(),
            },
          )}
          onClick={handleSend}
          disabled={draft?.isSending}
          aria-label="Send message"
        >
          <Icon name="solid-send" className="text-sm" />
        </button>
      </div>
    );
  },
);

ChatMessageInput.displayName = "ChatMessageInput";
