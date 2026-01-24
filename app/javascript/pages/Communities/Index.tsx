import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Community, CommunityNotificationSettings } from "$app/data/communities";

import { CommunitiesProvider } from "./CommunitiesContext";
import { CommunityView } from "./components/CommunityView";

type Props = {
  has_products: boolean;
  communities: Community[];
  notification_settings: CommunityNotificationSettings;
  selected_seller_id: string | null;
  selected_community_id: string | null;
};

function CommunitiesIndex() {
  const props = cast<Props>(usePage().props);

  return (
    <CommunitiesProvider initialData={props}>
      <CommunityView />
    </CommunitiesProvider>
  );
}

CommunitiesIndex.disableLayout = true;
export default CommunitiesIndex;
