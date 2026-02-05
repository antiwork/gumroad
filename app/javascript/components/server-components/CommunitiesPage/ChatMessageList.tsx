import cx from "classnames";
import React from "react";

import { Community, CommunityChatMessage } from "$app/data/communities";

import { ChatMessage } from "./ChatMessage";
import { scrollTo } from "./CommunityView";
import { DateSeparator, UnreadSeparator } from "./Separator";
import { CommunityChat } from "./useCommunities";

type ChatMessageListProps = {
  community: Community;
  data: CommunityChat;
  setStickyDate: (date: string | null) => void;
  unreadSeparatorVisibility: boolean;
};

export const ChatMessageList = ({
  community,
  data,
  setStickyDate,
  unreadSeparatorVisibility,
}: ChatMessageListProps) => {
  const [isVisible, setIsVisible] = React.useState(false);
  const [initialScrollDone, setInitialScrollDone] = React.useState(false);
  const [visibleDateGroups, setVisibleDateGroups] = React.useState<string[]>([]);
  const [invisibleDateGroups, setInvisibleDateGroups] = React.useState<string[]>([]);
  const dateObserversRef = React.useRef<Map<string, IntersectionObserver>>(new Map());
  const dateElementsRef = React.useRef<Map<string, HTMLDivElement>>(new Map());

  const isSafari = typeof window !== "undefined" && /^((?!chrome|android).)*safari/iu.test(navigator.userAgent);

  const lastReadMessageCreatedAt = community.last_read_community_chat_message_created_at;
  let lastReadMessageIndex = -1;
  if (lastReadMessageCreatedAt) {
    lastReadMessageIndex = data.messages.findIndex((message) => message.created_at === lastReadMessageCreatedAt);
    if (lastReadMessageIndex === -1) {
      lastReadMessageIndex = data.messages.findIndex(
        (message) => new Date(message.created_at) < new Date(lastReadMessageCreatedAt),
      );
    }
  }

  React.useEffect(() => {
    if (initialScrollDone || data.messages.length <= 0) return;
    if (community.unread_count > 0) {
      if (lastReadMessageIndex !== -1) {
        scrollTo({ target: "unread-separator" });
      } else {
        scrollTo({ target: "top" });
      }
    } else {
      scrollTo({ target: "bottom" });
    }
    setInitialScrollDone(true);
  }, [community, data.messages, initialScrollDone, lastReadMessageIndex]);

  React.useEffect(() => {
    setIsVisible(true);
  }, []);

  const messagesByDate = React.useMemo(() => {
    const messagesByDate: Record<string, CommunityChatMessage[]> = {};
    data.messages.forEach((message) => {
      const messageDate = new Date(message.created_at);
      // Create date string based on local time components instead of UTC
      const dateString = `${messageDate.getFullYear()}-${String(messageDate.getMonth() + 1).padStart(2, "0")}-${String(messageDate.getDate()).padStart(2, "0")}`;
      if (!messagesByDate[dateString]) {
        messagesByDate[dateString] = [];
      }
      messagesByDate[dateString].push(message);
    });
    return messagesByDate;
  }, [data.messages]);

  const sortedDates = Object.keys(messagesByDate).sort();
  const lastMessageId = React.useMemo(() => data.messages[data.messages.length - 1]?.id, [data.messages]);

  // Determine which date groups are visible and which are not
  React.useEffect(() => {
    dateObserversRef.current.forEach((observer) => observer.disconnect());
    dateObserversRef.current.clear();

    sortedDates.forEach((date) => {
      const element = dateElementsRef.current.get(date);
      if (element) {
        const dateSeparator = element.querySelector("[data-separator='date']");

        // Observer for the date separator visibility
        const separatorObserver = new IntersectionObserver(([entry]) => {
          if (entry?.isIntersecting) {
            setInvisibleDateGroups((prev) => prev.filter((d) => d !== date));
          } else {
            setInvisibleDateGroups((prev) => (prev.includes(date) ? prev : [...prev, date].sort()));
          }
        });
        if (dateSeparator) separatorObserver.observe(dateSeparator);

        // Observer for the date group content visibility
        const groupObserver = new IntersectionObserver(([entry]) => {
          setVisibleDateGroups((prev) => {
            // Safari has issues with rapid IntersectionObserver callbacks,
            // causing the UI to jump around when scrolling.
            // So we skip updating the visible date groups in Safari.
            if (isSafari) return prev;

            if (entry?.isIntersecting && !prev.includes(date)) {
              return [...prev, date].sort();
            } else if (!entry?.isIntersecting && prev.includes(date)) {
              return prev.filter((d) => d !== date);
            }
            return prev;
          });
        });

        groupObserver.observe(element);
        dateObserversRef.current.set(date, groupObserver);
      }
    });

    return () => {
      dateObserversRef.current.forEach((observer) => observer.disconnect());
    };
  }, [sortedDates]);

  React.useEffect(() => {
    // Find the oldest visible date group which has an invisible date separator
    let oldestVisibleDate = null;
    for (const date of [...visibleDateGroups].sort()) {
      if (invisibleDateGroups.includes(date)) {
        oldestVisibleDate = date;
        break;
      }
    }
    setStickyDate(oldestVisibleDate);
  }, [visibleDateGroups, invisibleDateGroups]);

  return (
    <div className="flex min-h-full w-full flex-col" aria-label="Chat messages">
      <div data-id="top"></div>
      <div
        className={cx(
          "flex flex-1 flex-col justify-end gap-4 pb-4 opacity-0 transition-opacity delay-150 duration-300 ease-in-out",
          {
            "opacity-100": isVisible,
          },
        )}
      >
        {data.nextOlderTimestamp === null ? (
          <div className="px-6 pt-8">
            <div className="mb-2 text-3xl">👋</div>
            <h2 className="mb-2 text-xl font-bold">Welcome to {community.name}</h2>
            <p className="text-sm text-gray-500">This is the start of this community chat.</p>
          </div>
        ) : null}

        {community.unread_count > 0 && lastReadMessageIndex === -1 && data.messages.length > 0 && (
          <UnreadSeparator visible={unreadSeparatorVisibility} />
        )}
        {sortedDates.map((date) => (
          <div className="flex flex-col gap-4" key={date} ref={(el) => el && dateElementsRef.current.set(date, el)}>
            <DateSeparator date={date} />
            {messagesByDate[date]?.map((message) => {
              const isLastReadMessage = lastReadMessageCreatedAt
                ? message.created_at === lastReadMessageCreatedAt
                : false;
              return (
                <React.Fragment key={message.id}>
                  <ChatMessage
                    message={message}
                    isLast={message.id === lastMessageId}
                    communitySellerId={community.seller.id}
                  />
                  {isLastReadMessage && community.unread_count > 0 ? (
                    <UnreadSeparator visible={unreadSeparatorVisibility} />
                  ) : null}
                </React.Fragment>
              );
            })}
          </div>
        ))}
      </div>
      <div data-id="bottom"></div>
    </div>
  );
};
