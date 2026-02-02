import { usePage } from "@inertiajs/react";
import * as React from "react";

import { Community, CommunityChatMessage, CommunityNotificationSettings } from "$app/data/communities";

import { CommunityView } from "$app/components/Communities";
import { LoggedInUserLayout } from "$app/inertia/layout";

type MessagesProps = {
  messages: CommunityChatMessage[];
  next_older_timestamp: string | null;
  next_newer_timestamp: string | null;
  current_cursor: string;
} | null;

type Props = {
  has_products: boolean;
  communities: Community[];
  notification_settings: CommunityNotificationSettings;
  selected_community_id: string | null;
  messages: MessagesProps;
}

function CommunitiesPage() {
  const props = usePage<Props>().props;

  return (
    <CommunityView
      initialData={{
        hasProducts: props.has_products,
        communities: props.communities,
        notificationSettings: props.notification_settings,
        selectedCommunityId: props.selected_community_id,
        messages: props.messages,
      }}
    />
  );
}

CommunitiesPage.layout = (page: React.ReactNode) => <LoggedInUserLayout>{page}</LoggedInUserLayout>;

export default CommunitiesPage;
