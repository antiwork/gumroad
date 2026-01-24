import * as React from "react";

import { Community, CommunityChatMessage, CommunityNotificationSettings } from "$app/data/communities";
import { assertDefined } from "$app/utils/assert";

export type CommunityDraft = {
  content: string;
  isSending: boolean;
};

export type CommunityChat = {
  messages: CommunityChatMessage[];
  nextOlderTimestamp: string | null;
  nextNewerTimestamp: string | null;
  isLoading: boolean;
};

type CommunitiesContextType = {
  hasProducts: boolean;
  communities: Community[];
  notificationSettings: CommunityNotificationSettings;
  selectedCommunity: Community | undefined;
  selectedCommunityDraft: CommunityDraft | null;
  selectedCommunityChat: CommunityChat | null;
  updateCommunity: (communityId: string, value: Partial<Omit<Community, "id" | "seller">>) => void;
  setSelectedCommunityId: (id: string | null) => void;
  setNotificationSettings: React.Dispatch<React.SetStateAction<CommunityNotificationSettings>>;
  updateCommunityDraft: (communityId: string, value: Partial<CommunityDraft>) => void;
  updateCommunityChat: (
    communityId: string,
    value: Partial<CommunityChat> | ((prev: CommunityChat) => Partial<CommunityChat>),
    options: { messagesUpdateStrategy: "replace" | "merge" },
  ) => void;
};

type CommunitiesProviderProps = {
  initialData: {
    has_products: boolean;
    communities: Community[];
    notification_settings: CommunityNotificationSettings;
    selected_seller_id: string | null;
    selected_community_id: string | null;
  };
  children: React.ReactNode;
};

const sortByCreatedAt = <T extends { created_at: string }>(items: readonly T[]) =>
  [...items].sort((a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime());

const sortByName = <T extends { name: string }>(items: readonly T[]) =>
  [...items].sort((a, b) => a.name.localeCompare(b.name));

export const CommunitiesContext = React.createContext<CommunitiesContextType | null>(null);

export const CommunitiesProvider = ({ initialData, children }: CommunitiesProviderProps) => {
  const [communities, setCommunities] = React.useState<Community[]>(sortByName(initialData.communities));
  const [notificationSettings, setNotificationSettings] = React.useState<CommunityNotificationSettings>(
    initialData.notification_settings,
  );
  const [selectedCommunityId, setSelectedCommunityId] = React.useState<string | null>(
    initialData.selected_community_id ?? null,
  );
  const [communityDrafts, setCommunityDrafts] = React.useState<Record<string, CommunityDraft>>({});
  const [communityChats, setCommunityChats] = React.useState<Record<string, CommunityChat>>({});

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

  const updateCommunityChat = React.useCallback(
    (
      communityId: string,
      value: Partial<CommunityChat> | ((prev: CommunityChat) => Partial<CommunityChat>),
      { messagesUpdateStrategy }: { messagesUpdateStrategy: "replace" | "merge" },
    ) =>
      setCommunityChats((prev) => {
        const obj = { ...prev };
        const prevChat = obj[communityId] ?? {
          messages: [],
          nextOlderTimestamp: null,
          nextNewerTimestamp: null,
          isLoading: false,
        };
        const { messages: newChatMessages = [], ...newChatExceptMessages } =
          typeof value === "function" ? value(prevChat) : value;

        if (messagesUpdateStrategy === "merge") {
          let messages: CommunityChatMessage[] = [];
          const { messages: prevChatMessages, ...prevChatExceptMessages } = prevChat;

          if (prevChatMessages.length > 0 && newChatMessages.length > 0) {
            const map = new Map<string, CommunityChatMessage>(prevChatMessages.map((message) => [message.id, message]));
            prevChatMessages.forEach((newMessage) => map.set(newMessage.id, newMessage));
            newChatMessages.forEach((newMessage) => {
              const prevMessage = map.get(newMessage.id);
              if (!prevMessage || new Date(prevMessage.updated_at) < new Date(newMessage.updated_at)) {
                map.set(newMessage.id, newMessage);
              }
            });
            messages = [...map.values()];
          } else {
            messages = [...prevChatMessages, ...newChatMessages];
          }

          obj[communityId] = {
            ...prevChatExceptMessages,
            ...newChatExceptMessages,
            messages: sortByCreatedAt(messages),
          };
        } else {
          obj[communityId] = {
            ...prevChat,
            ...newChatExceptMessages,
            messages: sortByCreatedAt(newChatMessages),
          };
        }
        return obj;
      }),
    [],
  );

  const selectedCommunity = React.useMemo(
    () => communities.find((community) => community.id === selectedCommunityId),
    [communities, selectedCommunityId],
  );

  const selectedCommunityDraft = React.useMemo(
    () => (selectedCommunity ? (communityDrafts[selectedCommunity.id] ?? null) : null),
    [communityDrafts, selectedCommunity],
  );

  const selectedCommunityChat = React.useMemo(
    () => (selectedCommunity ? (communityChats[selectedCommunity.id] ?? null) : null),
    [communityChats, selectedCommunity],
  );

  const contextValue = React.useMemo(
    () => ({
      hasProducts: initialData.has_products,
      communities,
      notificationSettings,
      selectedCommunity,
      selectedCommunityDraft,
      selectedCommunityChat,
      updateCommunity,
      setSelectedCommunityId,
      setNotificationSettings,
      updateCommunityDraft,
      updateCommunityChat,
    }),
    [
      initialData.has_products,
      communities,
      notificationSettings,
      selectedCommunity,
      selectedCommunityDraft,
      selectedCommunityChat,
      updateCommunity,
      updateCommunityDraft,
      updateCommunityChat,
    ],
  );

  return <CommunitiesContext.Provider value={contextValue}>{children}</CommunitiesContext.Provider>;
};

export const useCommunities = () => {
  const context = React.useContext(CommunitiesContext);
  if (!context) throw new Error("useCommunities must be used within CommunitiesProvider");
  return context;
};
