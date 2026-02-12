import { Channel } from "@anycable/web";
import { usePage, router } from "@inertiajs/react";
import cx from "classnames";
import { debounce } from "lodash-es";
import * as React from "react";
import { is } from "ts-safe-cast";

import cable from "$app/channels/consumer";
import { assertDefined } from "$app/utils/assert";

import { Button, NavigationButton } from "$app/components/Button";
import { ChatMessageInput } from "$app/components/Communities//ChatMessageInput";
import { ChatMessageList } from "$app/components/Communities/ChatMessageList";
import { CommunityList } from "$app/components/Communities/CommunityList";
import { ScrollToBottomButton } from "$app/components/Communities/ScrollToBottomButton";
import { scrollTo } from "$app/components/Communities/scrollUtils";
import { DateSeparator } from "$app/components/Communities/Separator";
import type {
  Community,
  CommunityChatMessage,
  CommunityDraft,
  NotificationSettings,
  Seller,
  CommunityNotificationSettings,
} from "$app/components/Communities/types";
import { UserAvatar } from "$app/components/Communities/UserAvatar";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { useRunOnce } from "$app/components/useRunOnce";

import placeholderImage from "$assets/images/placeholders/community.png";

type Props = {
  has_products: boolean;
  communities: Community[];
  notification_settings: CommunityNotificationSettings;
  selected_community_id: string | null;
  messages: CommunityChatMessage[] | null;
};

const COMMUNITY_CHANNEL_NAME = "CommunityChannel";
const USER_CHANNEL_NAME = "UserChannel";

export const MIN_MESSAGE_LENGTH = 1;

type IncomingCommunityChannelMessage =
  | { type: "create_chat_message"; message: CommunityChatMessage }
  | { type: "update_chat_message"; message: CommunityChatMessage }
  | { type: "delete_chat_message"; message: CommunityChatMessage };
type IncomingUserChannelMessage = { type: "latest_community_info"; data: Community };
type OutgoingUserChannelMessage = { type: "latest_community_info"; community_id: string };

const sortByCreatedAt = <T extends { created_at: string }>(items: readonly T[]) =>
  [...items].sort((a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime());

const sortByName = <T extends { name: string }>(items: readonly T[]) =>
  [...items].sort((a, b) => a.name.localeCompare(b.name));

function CommunityView() {
  const {
    has_products: hasProducts,
    communities: initialCommunities,
    notification_settings: notificationSettings,
    selected_community_id: selectedCommunityId,
    messages,
  } = usePage<Props>().props;
  const hasOlderMessages = usePage().scrollProps?.messages?.previousPage != null;

  const currentSeller = useCurrentSeller();
  const isAboveBreakpoint = useIsAboveBreakpoint("lg");

  const [communities, setCommunities] = React.useState<Community[]>(sortByName(initialCommunities));
  const [communityDrafts, setCommunityDrafts] = React.useState<Record<string, CommunityDraft>>({});

  // Local messages from WebSocket - merged with Inertia messages
  const [localMessages, setLocalMessages] = React.useState<CommunityChatMessage[]>([]);

  React.useEffect(() => {
    setLocalMessages([]);
  }, [selectedCommunityId]);

  // Merge Inertia messages with local WebSocket updates
  const allMessages = React.useMemo(() => {
    const serverMessages = messages ?? [];
    if (serverMessages.length === 0 && localMessages.length === 0) return [];

    const merged = new Map<string, CommunityChatMessage>();
    serverMessages.forEach((m) => merged.set(m.id, m));
    localMessages.forEach((m) => {
      const existing = merged.get(m.id);
      if (!existing || new Date(m.updated_at) > new Date(existing.updated_at)) {
        merged.set(m.id, m);
      }
    });
    return sortByCreatedAt([...merged.values()]);
  }, [messages, localMessages]);

  const selectedCommunity = React.useMemo(
    () => communities.find((community) => community.id === selectedCommunityId),
    [communities, selectedCommunityId],
  );

  const selectedCommunityDraft = React.useMemo(
    () => (selectedCommunity ? communityDrafts[selectedCommunity.id] : null),
    [communityDrafts, selectedCommunity],
  );

  const [switcherOpen, setSwitcherOpen] = React.useState(false);
  const [sidebarOpen, setSidebarOpen] = React.useState(true);
  const chatContainerRef = React.useRef<HTMLDivElement>(null);
  const notificationsHandledRef = React.useRef(false);
  const [scrollToMessage, setScrollToMessage] = React.useState<{
    id: string;
    position?: ScrollLogicalPosition;
  } | null>(null);
  const [stickyDate, setStickyDate] = React.useState<string | null>(null);
  const chatMessageInputRef = React.useRef<HTMLTextAreaElement>(null);
  const [showScrollToBottomButton, setShowScrollToBottomButton] = React.useState(false);
  const communityChannelsRef = React.useRef<Record<string, Channel>>({});
  const userChannelRef = React.useRef<Channel | null>(null);
  const [chatMessageInputHeight, setChatMessageInputHeight] = React.useState(0);
  const [showNotificationsSettings, setShowNotificationsSettings] = React.useState(false);
  const isSendingMessageRef = React.useRef(false);

  const updateCommunity = React.useCallback(
    (communityId: string, value: Partial<Omit<Community, "id" | "seller">>) =>
      setCommunities((prev) => {
        const obj = [...prev];
        const index = obj.findIndex((community) => community.id === communityId);
        if (index !== -1) {
          obj[index] = { ...assertDefined(obj[index]), ...value };
        }
        return obj;
      }),
    [],
  );

  const updateCommunityDraft = React.useCallback(
    (communityId: string, value: Partial<CommunityDraft>) =>
      setCommunityDrafts((prev) => {
        const obj = { ...prev };
        const draft = obj[communityId] ?? { content: "", isSending: false };
        obj[communityId] = { ...draft, ...value };
        return obj;
      }),
    [],
  );

  React.useEffect(() => {
    if (selectedCommunity && !notificationsHandledRef.current) {
      const url = new URL(window.location.href);
      if (url.searchParams.has("notifications")) {
        notificationsHandledRef.current = true;
        setShowNotificationsSettings(true);
        url.searchParams.delete("notifications");
        router.visit(url.toString(), { replace: true, preserveState: true, preserveScroll: true });
      }
    }
  }, [selectedCommunity]);

  const debouncedMarkAsRead = React.useMemo(
    () =>
      debounce((communityId: string, messageId: string, messageCreatedAt: string) => {
        if (!communityId || !messageId) return;
        router.post(
          Routes.mark_read_chat_messages_path(communityId),
          { message_id: messageId },
          {
            async: true,
            preserveState: true,
            preserveScroll: true,
            only: ["communities"],
            onSuccess: () => {
              updateCommunity(communityId, {
                unread_count: 0,
                last_read_community_chat_message_created_at: messageCreatedAt,
              });
            },
          },
        );
      }, 500),
    [updateCommunity],
  );

  const markMessageAsRead = React.useCallback(
    (message: CommunityChatMessage) => {
      if (!selectedCommunity) return;

      // Only mark as read if the message is newer than the last read message
      if (new Date(message.created_at) <= new Date(selectedCommunity.last_read_community_chat_message_created_at ?? 0))
        return;

      debouncedMarkAsRead(selectedCommunity.id, message.id, message.created_at);
    },
    [selectedCommunity, debouncedMarkAsRead],
  );

  React.useEffect(() => {
    if (allMessages.length === 0 || !scrollToMessage) return;
    const exists = allMessages.findIndex((message) => message.id === scrollToMessage.id) !== -1;
    if (exists && chatContainerRef.current) {
      scrollTo({
        target: "message",
        messageId: scrollToMessage.id,
        position: scrollToMessage.position ?? "nearest",
      });
      setScrollToMessage(null);
    }
  }, [scrollToMessage, allMessages]);

  React.useEffect(() => {
    if (!sidebarOpen) setSidebarOpen(true);
  }, [isAboveBreakpoint]);

  const handleScroll = useDebouncedCallback(() => {
    if (!chatContainerRef.current) return;
    const { scrollTop, scrollHeight, clientHeight } = chatContainerRef.current;
    const isNearBottom = scrollHeight - scrollTop - clientHeight < 50;
    setShowScrollToBottomButton(!isNearBottom);
  }, 100);

  const insertOrUpdateMessage = React.useCallback(
    (message: CommunityChatMessage, isUpdate = false) => {
      setLocalMessages((prev) => {
        const filtered = prev.filter((m) => m.id !== message.id);
        return [...filtered, message];
      });

      if (selectedCommunity?.id !== message.community_id || isUpdate) return;

      if (chatContainerRef.current) {
        const { scrollTop, scrollHeight, clientHeight } = chatContainerRef.current;
        const scrollPosition = scrollTop + clientHeight;
        const isNearBottom = scrollHeight - scrollPosition < 200;

        if (isNearBottom) {
          setScrollToMessage({ id: message.id, position: "start" });
        }
      }
    },
    [selectedCommunity?.id],
  );

  const removeMessage = React.useCallback((messageId: string) => {
    setLocalMessages((prev) => prev.filter((m) => m.id !== messageId));
  }, []);

  const sendMessage = () => {
    if (!selectedCommunity) return;
    if (!selectedCommunityDraft) return;
    if (selectedCommunityDraft.isSending) return;
    if (isSendingMessageRef.current) return;
    if (selectedCommunityDraft.content.trim() === "") return;

    const communityId = selectedCommunity.id;
    const messageContent = selectedCommunityDraft.content;

    isSendingMessageRef.current = true;
    updateCommunityDraft(communityId, { isSending: true });

    router.post(
      Routes.chat_messages_path(communityId),
      {
        community_chat_message: { content: messageContent },
      },
      {
        async: true,
        preserveState: true,
        preserveScroll: true,
        onSuccess: () => {
          updateCommunityDraft(communityId, { content: "", isSending: false });
        },
        onError: () => {
          updateCommunityDraft(communityId, { isSending: false });
        },
        onCancel: () => {
          updateCommunityDraft(communityId, { isSending: false });
        },
        onFinish: () => {
          isSendingMessageRef.current = false;
          updateCommunityDraft(communityId, { isSending: false });
          scrollTo({ target: "bottom" });
          setShowScrollToBottomButton(false);
        },
      },
    );
  };

  const loggedInUser = assertDefined(useCurrentSeller());

  React.useEffect(() => {
    if (!cable) return;

    const userChannelState = userChannelRef.current?.state;
    if (userChannelState === "connected" || userChannelState === "idle") return;

    const channel = cable.subscribeTo(USER_CHANNEL_NAME, { user_id: loggedInUser.id });
    userChannelRef.current = channel;

    channel.on("message", (msg) => {
      if (is<IncomingUserChannelMessage>(msg)) {
        updateCommunity(msg.data.id, {
          unread_count: msg.data.unread_count,
          last_read_community_chat_message_created_at: msg.data.last_read_community_chat_message_created_at,
        });
      }
    });

    return () => channel.disconnect();
  }, [cable, loggedInUser]);

  const sendMessageToUserChannel = useDebouncedCallback((msg: OutgoingUserChannelMessage) => {
    const userChannelState = userChannelRef.current?.state;
    if (userChannelState === "connected" || userChannelState === "idle") {
      userChannelRef.current?.send(msg).catch((e: unknown) => {
        // eslint-disable-next-line no-console
        console.error(e);
      });
    }
  }, 100);

  React.useEffect(() => {
    communities.forEach((community) => {
      if (!cable) return;
      const communityChannel = communityChannelsRef.current[community.id];
      const communityChannelState = communityChannel?.state;
      if (["connected", "connecting", "idle"].includes(communityChannelState ?? "")) return;
      const channel = cable.subscribeTo(COMMUNITY_CHANNEL_NAME, { community_id: community.id });
      communityChannelsRef.current[community.id] = channel;
      channel.on("message", (msg) => {
        if (is<IncomingCommunityChannelMessage>(msg)) {
          if (msg.type === "create_chat_message") {
            if (msg.message.community_id === community.id) {
              if (community.id === selectedCommunity?.id) {
                insertOrUpdateMessage(msg.message);
              }
            }
            sendMessageToUserChannel({ type: "latest_community_info", community_id: community.id });
          } else if (msg.type === "update_chat_message") {
            if (msg.message.community_id === community.id && community.id === selectedCommunity?.id) {
              insertOrUpdateMessage(msg.message, true);
            }
          } else if (msg.message.community_id === community.id) {
            if (community.id === selectedCommunity?.id) {
              removeMessage(msg.message.id);
            }
            sendMessageToUserChannel({ type: "latest_community_info", community_id: community.id });
          }
        }
      });
    });

    return () => {
      Object.values(communityChannelsRef.current).forEach((channel) => {
        if (channel.state !== "disconnected" && channel.state !== "closed") {
          channel.disconnect();
        }
      });
    };
  }, [cable, communities, selectedCommunity, insertOrUpdateMessage, removeMessage, sendMessageToUserChannel]);

  React.useEffect(() => chatMessageInputRef.current?.focus(), [selectedCommunity?.id]);

  const switchSeller = (sellerId: string) => {
    const community = communities.find((community) => community.seller.id === sellerId);
    if (community) {
      router.visit(Routes.community_path(community.seller.id, community.id), {
        preserveState: true,
        preserveScroll: true,
      });
      setSwitcherOpen(false);
    }
  };

  useRunOnce(() => {
    if (selectedCommunity) return;

    const firstCommunity = communities[0];
    if (!firstCommunity) return;

    let communityId;
    if (currentSeller) {
      const community = communities.find((community) => community.seller.id === currentSeller.id);
      if (community) {
        communityId = community.id;
      } else {
        communityId = firstCommunity.id;
      }
    } else {
      communityId = firstCommunity.id;
    }

    const community = communities.find((community) => community.id === communityId);
    if (!community) return;
    router.visit(Routes.community_path(community.seller.id, community.id), {
      preserveState: true,
      preserveScroll: true,
    });
  });

  const sellers = React.useMemo(() => {
    const obj = communities.reduce<Record<string, Seller>>((acc, community) => {
      if (!acc[community.seller.id]) {
        acc[community.seller.id] = community.seller;
      }
      return acc;
    }, {});

    return Object.values(obj).sort((a, b) => a.name.localeCompare(b.name));
  }, [communities]);

  const sellersExceptSelected = React.useMemo(
    () => sellers.filter((seller) => seller.id !== selectedCommunity?.seller.id),
    [sellers, selectedCommunity],
  );

  const selectedSellerCommunities = React.useMemo(
    () => communities.filter((community) => community.seller.id === selectedCommunity?.seller.id),
    [communities, selectedCommunity],
  );

  const saveNotificationsSettings = (community: Community, settings: NotificationSettings) => {
    router.put(
      Routes.notification_settings_path(community.id),
      { settings },
      {
        preserveState: true,
        preserveScroll: true,
        onSuccess: () => {
          setShowNotificationsSettings(false);
        },
      },
    );
  };

  const scrollToBottom = () => {
    if (selectedCommunity && selectedCommunity.unread_count > 0) {
      router.reload({
        only: ["messages"],
        onSuccess: () => {
          setTimeout(() => scrollTo({ target: "bottom" }), 100);
        },
      });
    } else {
      scrollTo({ target: "bottom" });
    }
    setShowScrollToBottomButton(false);
  };

  return (
    <>
      <div className="flex h-screen flex-col">
        <GoBackHeader />

        {communities.length === 0 ? (
          <EmptyCommunitiesPlaceholder hasProducts={hasProducts} />
        ) : selectedCommunity ? (
          <div className="flex flex-1 overflow-hidden">
            <div
              className={cx("flex shrink-0 flex-col overflow-hidden", {
                "relative w-72 border-r dark:border-[rgb(var(--parent-color)/var(--border-alpha))]": isAboveBreakpoint,
                "absolute inset-0 top-12 z-30 bg-gray dark:bg-dark-gray": !isAboveBreakpoint && sidebarOpen,
                "w-0 overflow-hidden": !isAboveBreakpoint && !sidebarOpen,
              })}
              aria-label="Sidebar"
            >
              <div className="flex items-center gap-2 border-b p-2 dark:border-[rgb(var(--parent-color)/var(--border-alpha))]">
                <div className="flex flex-1 items-center gap-2" aria-label="Community switcher area">
                  <UserAvatar
                    src={selectedCommunity.seller.avatar_url}
                    alt={selectedCommunity.seller.name}
                    className="shrink-0 dark:border-[rgb(var(--parent-color)/var(--border-alpha))]"
                  />
                  <div className="flex items-center font-medium">
                    <span className="flex-1 truncate">
                      {currentSeller?.id === selectedCommunity.seller.id
                        ? "My community"
                        : selectedCommunity.seller.name}
                    </span>

                    <Popover open={switcherOpen} onOpenChange={setSwitcherOpen}>
                      <PopoverTrigger aria-label="Switch creator" className="flex h-8 w-8 justify-center">
                        <Icon name="outline-cheveron-down" />
                      </PopoverTrigger>
                      <PopoverContent className="shrink-0 border-0 p-0 shadow-none">
                        <div role="menu">
                          {sellersExceptSelected.map((seller) => (
                            <div
                              key={seller.id}
                              role="menuitem"
                              className="max-w-xs"
                              onClick={() => switchSeller(seller.id)}
                            >
                              <div className="flex items-center gap-1">
                                <UserAvatar
                                  src={seller.avatar_url}
                                  alt={seller.name}
                                  className="shrink-0"
                                  size="small"
                                />
                                <span className="truncate">
                                  {seller.name} {currentSeller?.id === seller.id ? <em>(your community)</em> : null}
                                </span>
                              </div>
                            </div>
                          ))}
                          {sellersExceptSelected.length > 0 ? <hr className="my-1" /> : null}
                          <div role="menuitem" onClick={() => setShowNotificationsSettings(true)}>
                            <Icon name="outline-bell" /> Notifications
                          </div>
                        </div>
                      </PopoverContent>
                    </Popover>
                  </div>
                </div>

                <button
                  onClick={() => setSidebarOpen(false)}
                  className={cx("flex h-8 w-8 cursor-pointer justify-center all-unset", {
                    hidden: isAboveBreakpoint,
                  })}
                  aria-label="Close sidebar"
                >
                  <Icon name="x" className="text-sm" />
                </button>
              </div>

              <CommunityList
                communities={selectedSellerCommunities}
                selectedCommunity={selectedCommunity}
                isAboveBreakpoint={isAboveBreakpoint}
                setSidebarOpen={setSidebarOpen}
              />
            </div>

            <div className="flex flex-1 flex-col overflow-hidden bg-white dark:bg-black" aria-label="Chat window">
              <CommunityChatHeader
                community={selectedCommunity}
                setSidebarOpen={setSidebarOpen}
                isAboveBreakpoint={isAboveBreakpoint}
              />

              <div className="flex flex-1 overflow-auto">
                <div ref={chatContainerRef} className="relative flex-1 overflow-y-auto" onScroll={handleScroll}>
                  <div
                    className={cx("sticky top-0 z-20 flex justify-center transition-opacity duration-300", {
                      "opacity-100": stickyDate,
                      "opacity-0": !stickyDate,
                    })}
                  >
                    {stickyDate ? <DateSeparator date={stickyDate} showDividerLine={false} /> : null}
                  </div>

                  <ChatMessageList
                    key={selectedCommunity.id}
                    community={selectedCommunity}
                    messages={allMessages}
                    hasOlderMessages={hasOlderMessages}
                    setStickyDate={setStickyDate}
                    unreadSeparatorVisibility={showScrollToBottomButton}
                    markMessageAsRead={markMessageAsRead}
                  />
                  {showScrollToBottomButton ? (
                    <ScrollToBottomButton
                      hasUnreadMessages={selectedCommunity.unread_count > 0}
                      onClick={scrollToBottom}
                      chatMessageInputHeight={chatMessageInputHeight}
                    />
                  ) : null}
                </div>
              </div>

              <div className="px-6 pb-4">
                <ChatMessageInput
                  draft={selectedCommunityDraft ?? null}
                  updateDraftMessage={(content) => updateCommunityDraft(selectedCommunity.id, { content })}
                  onSend={sendMessage}
                  ref={chatMessageInputRef}
                  onHeightChange={setChatMessageInputHeight}
                />
              </div>
            </div>
          </div>
        ) : null}
      </div>
      {showNotificationsSettings && selectedCommunity ? (
        <NotificationsSettingsModal
          communityName={selectedCommunity.seller.name}
          settings={notificationSettings[selectedCommunity.seller.id] ?? { recap_frequency: null }}
          onClose={() => setShowNotificationsSettings(false)}
          onSave={(settings) => saveNotificationsSettings(selectedCommunity, settings)}
        />
      ) : null}
    </>
  );
}

const NotificationsSettingsModal = ({
  communityName,
  settings,
  onClose,
  onSave,
}: {
  communityName: string;
  settings: NotificationSettings;
  onClose: () => void;
  onSave: (settings: NotificationSettings) => void;
}) => {
  const [isSaving, setIsSaving] = React.useState(false);
  const [updatedSettings, setUpdatedSettings] = React.useState<NotificationSettings>(settings);

  return (
    <Modal
      open
      allowClose={false}
      onClose={onClose}
      title="Notifications"
      footer={
        <>
          <Button disabled={isSaving} onClick={onClose}>
            Cancel
          </Button>
          <Button
            color="primary"
            onClick={() => {
              setIsSaving(true);
              onSave(updatedSettings);
              setIsSaving(false);
            }}
          >
            {isSaving ? "Saving..." : "Save"}
          </Button>
        </>
      }
    >
      <p>Receive email recaps of what's happening in "{communityName}" community.</p>
      <ToggleSettingRow
        label="Community recap"
        value={updatedSettings.recap_frequency !== null}
        onChange={(newValue) => setUpdatedSettings({ ...updatedSettings, recap_frequency: newValue ? "weekly" : null })}
        dropdown={
          <div className="radio-buttons flex! flex-col!" role="radiogroup">
            <Button
              role="radio"
              aria-checked={updatedSettings.recap_frequency === "daily"}
              onClick={() => setUpdatedSettings({ ...updatedSettings, recap_frequency: "daily" })}
            >
              <div>
                <h4>Daily</h4>
                <p>Get a summary of activity every day</p>
              </div>
            </Button>
            <Button
              role="radio"
              aria-checked={updatedSettings.recap_frequency === "weekly"}
              onClick={() => setUpdatedSettings({ ...updatedSettings, recap_frequency: "weekly" })}
            >
              <div>
                <h4>Weekly</h4>
                <p>Receive a weekly summary every Sunday</p>
              </div>
            </Button>
          </div>
        }
      />
    </Modal>
  );
};

const CommunityChatHeader = ({
  community,
  setSidebarOpen,
  isAboveBreakpoint,
}: {
  community: Community;
  setSidebarOpen: (open: boolean) => void;
  isAboveBreakpoint: boolean;
}) => (
  <div
    className="m-0 flex justify-between gap-2 border-b px-4 dark:border-[rgb(var(--parent-color)/var(--border-alpha))]"
    aria-label="Community chat header"
  >
    <button
      className={cx("shrink-0 cursor-pointer all-unset", { hidden: isAboveBreakpoint })}
      aria-label="Open sidebar"
      onClick={() => setSidebarOpen(true)}
    >
      <Icon name="outline-cheveron-left" className="text-sm" />
    </button>
    <h1 className="flex-1 truncate py-3 text-base font-bold">{community.name}</h1>
  </div>
);

const GoBackHeader = () => {
  const handleGoBack = (e: React.MouseEvent) => {
    e.preventDefault();
    const referrerUrl = new URL(document.referrer.trim() !== "" ? document.referrer : Routes.dashboard_url());
    const targetPath = referrerUrl.pathname.startsWith("/communities") ? Routes.dashboard_path() : referrerUrl.pathname;

    router.visit(targetPath, { replace: true });
  };

  return (
    <header className="flex h-12 items-center border-b px-4 dark:border-[rgb(var(--parent-color)/var(--border-alpha))]">
      <div className="flex items-center">
        <button
          onClick={handleGoBack}
          className="flex cursor-pointer items-center border-none bg-transparent p-0 text-sm no-underline all-unset"
        >
          <Icon name="arrow-left" className="mr-1" /> Go back
        </button>
      </div>
    </header>
  );
};

const EmptyCommunitiesPlaceholder = ({ hasProducts }: { hasProducts: boolean }) => (
  <div>
    <section>
      <Placeholder>
        <PlaceholderImage src={placeholderImage} />
        <h2>Build your community, one product at a time!</h2>
        <p className="max-w-prose">
          When you publish a product, we automatically create a dedicated community chat—your own space to connect with
          customers, answer questions, and build relationships.
        </p>
        <NavigationButton href={hasProducts ? Routes.products_path() : Routes.new_product_path()} color="accent">
          {hasProducts ? "Enable community chat for your products" : "Create a product with community"}
        </NavigationButton>
        <p>
          or{" "}
          <a href="/help/article/347-gumroad-community" target="_blank" rel="noreferrer">
            learn more about community chats
          </a>
        </p>
      </Placeholder>
    </section>
  </div>
);

CommunityView.loggedInUserLayout = true;
export default CommunityView;
