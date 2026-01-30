import { usePage } from "@inertiajs/react";
import * as React from "react";

import { Community, CommunityNotificationSettings } from "$app/data/communities";

import { CommunityView } from "$app/components/Communities";
import { LoggedInUserLayout } from "$app/inertia/layout";

type Props = {
  has_products: boolean;
  communities: Community[];
  notification_settings: CommunityNotificationSettings;
  selected_community_id: string | null;
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
      }}
    />
  );
}

CommunitiesPage.layout = (page: React.ReactNode) => <LoggedInUserLayout>{page}</LoggedInUserLayout>;

export default CommunitiesPage;
