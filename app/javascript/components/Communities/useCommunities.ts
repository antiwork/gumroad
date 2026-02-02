import * as React from "react";

import { Community, CommunityChatMessage, CommunityNotificationSettings } from "$app/data/communities";
import { assertDefined } from "$app/utils/assert";

export type CommunityDraft = {
  content: string;
  isSending: boolean;
};

export type MessagesData = {
  messages: CommunityChatMessage[];
  next_older_timestamp: string | null;
  next_newer_timestamp: string | null;
  current_cursor: string;
};

export interface InitialCommunitiesData {
  hasProducts: boolean;
  communities: Community[];
  notificationSettings: CommunityNotificationSettings;
  selectedCommunityId: string | null;
  messages: MessagesData | null;
}

const sortByName = <T extends { name: string }>(items: readonly T[]) =>
  [...items].sort((a, b) => a.name.localeCompare(b.name));

export const useCommunities = ({
  hasProducts,
  communities: initialCommunities,
  notificationSettings,
  selectedCommunityId,
  messages: initialMessages,
}: InitialCommunitiesData) => {
  const [communities, setCommunities] = React.useState<Community[]>(sortByName(initialCommunities));
  const [communityDrafts, setCommunityDrafts] = React.useState<Record<string, CommunityDraft>>({});
  const [messages, setMessages] = React.useState<MessagesData | null>(initialMessages);

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

  const updateMessages = React.useCallback(
    (updater: (prev: MessagesData | null) => MessagesData | null) => {
      setMessages(updater);
    },
    [],
  );

  React.useEffect(() => {
    setCommunities(sortByName(initialCommunities));
  }, [initialCommunities]);

  React.useEffect(() => {
    setMessages(initialMessages);
  }, [initialMessages]);

  const selectedCommunity = React.useMemo(
    () => communities.find((community) => community.id === selectedCommunityId),
    [communities, selectedCommunityId],
  );

  const selectedCommunityDraft = React.useMemo(
    () => (selectedCommunity ? communityDrafts[selectedCommunity.id] : null),
    [communityDrafts, selectedCommunity],
  );

  return {
    hasProducts,
    communities,
    notificationSettings,
    messages,
    selectedCommunity,
    selectedCommunityDraft,
    updateCommunity,
    updateCommunityDraft,
    updateMessages,
  };
};
