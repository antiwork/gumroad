import { usePage } from "@inertiajs/react";
import React from "react";

import { CommunityView } from "$app/components/Communities/CommunityView";
import type { Community, CommunityChatMessage, CommunityNotificationSettings } from "$app/components/Communities/types";

type Props = {
  has_products: boolean;
  communities: Community[];
  notification_settings: CommunityNotificationSettings;
  selected_community_id: string | null;
  messages: {
    messages: CommunityChatMessage[];
    next_older_timestamp: string | null;
    next_newer_timestamp: string | null;
  } | null;
};

function CommunitiesIndex() {
  const props = usePage<Props>().props;

  return (
    <CommunityView
      hasProducts={props.has_products}
      communities={props.communities}
      notificationSettings={props.notification_settings}
      selectedCommunityId={props.selected_community_id}
      messages={props.messages}
    />
  );
}

CommunitiesIndex.loggedInUserLayout = true;
export default CommunitiesIndex;
