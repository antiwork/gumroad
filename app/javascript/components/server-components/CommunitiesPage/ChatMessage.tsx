import cx from "classnames";
import React from "react";

import { CommunityChatMessage } from "$app/data/communities";
import { asyncVoid } from "$app/utils/promise";

import { Button } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { useOnOutsideClick } from "$app/components/useOnOutsideClick";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useRunOnce } from "$app/components/useRunOnce";
import { WithTooltip } from "$app/components/WithTooltip";

import { CommunityViewContext, MAX_MESSAGE_LENGTH, MIN_MESSAGE_LENGTH } from "./CommunityView";
import { UserAvatar } from "./UserAvatar";

const MAX_TEXTAREA_HEIGHT = 300;

export const ChatMessage = ({
  message,
  isLast,
  communitySellerId,
}: {
  message: CommunityChatMessage;
  isLast: boolean;
  communitySellerId: string;
}) => {
  const userAgentInfo = useUserAgentInfo();
  const messageRef = React.useRef<HTMLDivElement>(null);
  const { markMessageAsRead, updateMessage, deleteMessage } = React.useContext(CommunityViewContext);
  const wasVisibleRef = React.useRef(false);
  const [isHovered, setIsHovered] = React.useState(false);
  const [isEditing, setIsEditing] = React.useState(false);
  const currentSeller = useCurrentSeller();
  const [isSaving, setIsSaving] = React.useState(false);
  const [deleteConfirmation, setDeleteConfirmation] = React.useState<{ deleting: boolean } | null>(null);

  const isOwnMessage = currentSeller?.id === message.user.id;
  const isCommunitySeller = currentSeller?.id === communitySellerId;
  const canShowActions = isHovered && !isEditing && (isOwnMessage || isCommunitySeller);

  React.useEffect(() => {
    if (!messageRef.current) return;

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries[0]?.isIntersecting) {
          wasVisibleRef.current = true;
          // If it's the last message, mark it as read since it may not be scrolled down further
          if (isLast) markMessageAsRead(message);
        } else if (wasVisibleRef.current) {
          wasVisibleRef.current = false;
          markMessageAsRead(message);
        }
      },
      { threshold: 0.5 },
    );

    observer.observe(messageRef.current);
    return () => observer.disconnect();
  }, [message.id, markMessageAsRead, isLast]);

  const isAboveBreakpoint = useIsAboveBreakpoint("lg");
  useOnOutsideClick([messageRef], () => !isAboveBreakpoint && isHovered && setIsHovered(false));

  const handleClick = () => {
    if (!isAboveBreakpoint) {
      setIsHovered(!isHovered);
    }
  };

  const handleEdit = (e: React.MouseEvent) => {
    e.stopPropagation();
    setIsEditing(true);
  };

  const handleCancelEdit = () => {
    setIsEditing(false);
  };

  const handleSaveEdit = async (editedMessage: string) => {
    setIsSaving(true);
    try {
      if (editedMessage.length < MIN_MESSAGE_LENGTH) {
        showAlert(`Message must be at least ${MIN_MESSAGE_LENGTH} characters long.`, "error");
        return;
      }
      if (editedMessage.length > MAX_MESSAGE_LENGTH) {
        showAlert(`Message is too long.`, "error");
        return;
      }
      await updateMessage(message.id, message.community_id, editedMessage);
      setIsEditing(false);
    } catch (_e: unknown) {
      showAlert("Failed to update message.", "error");
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <div
      className={cx("group relative flex items-start gap-2 px-6 py-2", {
        "bg-gray dark:bg-dark-gray": isHovered && !isEditing,
        "bg-pink/10": isEditing,
      })}
      data-id={`message-${message.id}`}
      ref={messageRef}
      onMouseEnter={() => setIsHovered(true)}
      onMouseLeave={() => setIsHovered(false)}
      onClick={handleClick}
      aria-label="Chat message"
    >
      <UserAvatar
        src={message.user.avatar_url}
        alt={message.user.name}
        className="shrink-0 dark:border-[rgb(var(--parent-color)/var(--border-alpha))]"
        size="large"
      />
      <div className="relative flex w-full flex-col gap-0.5">
        {isEditing ? null : (
          <div className="flex items-center gap-2">
            <span className="font-bold">{message.user.name}</span>
            {message.user.is_seller ? (
              <span className="rounded-sm border px-1 py-0.25 text-[10px] font-bold tracking-wider uppercase dark:text-gray">
                Creator
              </span>
            ) : null}
            <time
              className="text-muted text-xs"
              title={new Date(message.created_at).toLocaleString(userAgentInfo.locale, {
                dateStyle: "full",
                timeStyle: "short",
              })}
            >
              {new Date(message.created_at).toLocaleTimeString([], {
                hour: "2-digit",
                minute: "2-digit",
                hour12: true,
              })}
            </time>
          </div>
        )}

        {isEditing ? (
          <MessageEditor
            content={message.content}
            isSaving={isSaving}
            onCancel={handleCancelEdit}
            onSave={handleSaveEdit}
          />
        ) : (
          <div className="text-sm whitespace-pre-wrap" aria-label="Message content">
            {message.content}
          </div>
        )}

        {canShowActions ? (
          <div
            className="absolute -top-6 right-0 z-10 flex gap-1 rounded-md border bg-white p-1 hover:shadow-[4px_4px_black] dark:border-[rgb(var(--parent-color)/var(--border-alpha))] dark:bg-black dark:hover:shadow-[4px_4px_white]"
            aria-label="Actions"
          >
            {isOwnMessage ? (
              <>
                <WithTooltip position="top" tip="Edit">
                  <button
                    className="flex items-center rounded-md border-r border-gray-200 px-2 py-1.5 text-xs hover:bg-gray dark:hover:bg-dark-gray"
                    onClick={handleEdit}
                    aria-label="Edit message"
                  >
                    <Icon name="pencil" />
                  </button>
                </WithTooltip>
                <div className="flex border-r dark:border-[rgb(var(--parent-color)/var(--border-alpha))]" />
              </>
            ) : null}
            <WithTooltip position="top" tip="Delete">
              <button
                className="flex items-center rounded-md px-2 py-1.5 text-xs hover:bg-gray hover:text-red dark:hover:bg-dark-gray"
                onClick={() => setDeleteConfirmation({ deleting: false })}
                aria-label="Delete message"
              >
                <Icon name="trash2" />
              </button>
            </WithTooltip>
          </div>
        ) : null}
      </div>

      {deleteConfirmation ? (
        <Modal
          open
          allowClose={deleteConfirmation.deleting}
          onClose={() => setDeleteConfirmation(null)}
          title="Delete message"
          footer={
            <>
              <Button disabled={deleteConfirmation.deleting} onClick={() => setDeleteConfirmation(null)}>
                Cancel
              </Button>
              <Button
                color="danger"
                onClick={asyncVoid(async () => {
                  setDeleteConfirmation({ deleting: true });
                  try {
                    await deleteMessage(message.id, message.community_id);
                    setDeleteConfirmation(null);
                  } catch (_e: unknown) {
                    setDeleteConfirmation({ deleting: false });
                  }
                })}
              >
                {deleteConfirmation.deleting ? "Deleting..." : "Delete"}
              </Button>
            </>
          }
        >
          <h4>Are you sure you want to delete this message? This cannot be undone.</h4>
        </Modal>
      ) : null}
    </div>
  );
};

type MessageEditorProps = {
  content: string;
  isSaving: boolean;
  onCancel: () => void;
  onSave: (content: string) => Promise<void>;
};
const MessageEditor = ({ content: initialContent, isSaving, onCancel, onSave }: MessageEditorProps) => {
  const [editedContent, setEditedContent] = React.useState(initialContent);
  const textareaRef = React.useRef<HTMLTextAreaElement>(null);
  const [showMoreTextIndicator, setShowMoreTextIndicator] = React.useState(false);

  useRunOnce(() => {
    autoFocusTextarea();
    adjustTextareaHeight();
    scrollToEndOfTextarea();
    determineIfMoreTextIndicatorShouldBeShown();
  });

  const autoFocusTextarea = () => {
    if (textareaRef.current) {
      textareaRef.current.focus();
      const length = textareaRef.current.value.length;
      textareaRef.current.setSelectionRange(length, length);
    }
  };

  const adjustTextareaHeight = () => {
    if (textareaRef.current) {
      const textarea = textareaRef.current;
      textarea.style.height = "auto";
      const newHeight = Math.min(textarea.scrollHeight, MAX_TEXTAREA_HEIGHT);
      textarea.style.height = `${newHeight}px`;
    }
  };

  const scrollToEndOfTextarea = () => {
    if (textareaRef.current) {
      const textarea = textareaRef.current;
      textarea.scrollTop = textarea.scrollHeight;
    }
  };

  const determineIfMoreTextIndicatorShouldBeShown = () => {
    if (textareaRef.current) {
      const textarea = textareaRef.current;
      const isScrollable = textarea.scrollHeight > textarea.clientHeight;
      const isScrolledToBottom = Math.abs(textarea.scrollHeight - textarea.scrollTop - textarea.clientHeight) < 2;
      setShowMoreTextIndicator(isScrollable && !isScrolledToBottom);
    }
  };

  const handleKeyDown = async (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Escape") {
      onCancel();
    } else if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      await onSave(editedContent.trim());
    }
  };

  const isCursorAtEnd = () => {
    if (!textareaRef.current) return false;
    return textareaRef.current.selectionStart === textareaRef.current.value.length;
  };

  return (
    <div className="relative overflow-hidden rounded-md border focus-within:outline-[0.125rem] focus-within:outline-[rgb(var(--accent))] focus-within:outline-solid dark:border-[rgb(var(--parent-color)/var(--border-alpha))]">
      <textarea
        ref={textareaRef}
        placeholder="Edit message"
        className="max-h-[300px] min-h-[80px] w-full resize-none overflow-y-auto border-none p-2 pb-14 text-sm outline-hidden"
        value={editedContent}
        onChange={(e) => {
          setEditedContent(e.target.value);
          requestAnimationFrame(() => {
            adjustTextareaHeight();
            if (isCursorAtEnd()) scrollToEndOfTextarea();
            determineIfMoreTextIndicatorShouldBeShown();
          });
        }}
        onKeyDown={asyncVoid(handleKeyDown)}
        onScroll={determineIfMoreTextIndicatorShouldBeShown}
      />
      <div
        className={cx("absolute right-0 bottom-0 left-0 flex justify-end gap-2 bg-white p-2 dark:bg-black", {
          "border-t": showMoreTextIndicator,
        })}
        onClick={(e) => {
          e.stopPropagation();
          autoFocusTextarea();
          scrollToEndOfTextarea();
        }}
      >
        <Button small onClick={onCancel} disabled={isSaving}>
          Cancel
        </Button>
        <Button
          small
          color="accent"
          onClick={asyncVoid(async () => await onSave(editedContent.trim()))}
          disabled={isSaving}
        >
          {isSaving ? "Saving..." : "Save"}
        </Button>
      </div>
    </div>
  );
};
