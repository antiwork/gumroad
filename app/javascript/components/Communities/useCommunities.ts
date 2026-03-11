import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Community, CommunityNotificationSettings } from "$app/data/communities";
import { assertDefined } from "$app/utils/assert";

export type CommunityDraft = {
  content: string;
  isSending: boolean;
};

interface CommunitiesData {
  communities: Community[];
  notification_settings: CommunityNotificationSettings;
}

interface PageProps {
  has_products: boolean;
  communities_data?: CommunitiesData;
  selectedCommunityId?: string;
}

const sortByName = <T extends { name: string }>(items: readonly T[]) =>
  [...items].sort((a, b) => a.name.localeCompare(b.name));

export const useCommunities = () => {
  const pageProps = cast<PageProps>(usePage().props);
  const { has_products, communities_data, selectedCommunityId: initialSelectedCommunityId } = pageProps;

  const initialCommunities = communities_data?.communities ?? [];
  const notification_settings = communities_data?.notification_settings ?? {};

  const [communities, setCommunities] = React.useState<Community[]>(sortByName(initialCommunities));
  const [notificationSettings, setNotificationSettings] =
    React.useState<CommunityNotificationSettings>(notification_settings);
  const [selectedCommunityId, setSelectedCommunityId] = React.useState<string | null>(
    initialSelectedCommunityId ?? null,
  );
  const [communityDrafts, setCommunityDrafts] = React.useState<Record<string, CommunityDraft>>({});

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
    setSelectedCommunityId(initialSelectedCommunityId ?? null);
    setCommunities(sortByName(initialCommunities));
    setNotificationSettings(notification_settings);
  }, [initialSelectedCommunityId, initialCommunities, notification_settings]);

  const selectedCommunity = React.useMemo(
    () => communities.find((community) => community.id === selectedCommunityId),
    [communities, selectedCommunityId],
  );

  const selectedCommunityDraft = React.useMemo(
    () => (selectedCommunity ? communityDrafts[selectedCommunity.id] : null),
    [communityDrafts, selectedCommunity],
  );

  return {
    isLoading: !communities_data,
    hasProducts: has_products,
    communities,
    notificationSettings,
    selectedCommunity,
    selectedCommunityDraft,
    updateCommunity,
    updateCommunityDraft,
  };
};
