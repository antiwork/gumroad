import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { AnalyticsData } from "$app/parsers/product";
import { startTrackingForSeller, trackProfilePageView } from "$app/utils/user_analytics";

import { Profile } from "$app/components/Profile";
import { useAddProfileThirdPartyAnalytics } from "$app/components/useAddThirdPartyAnalytics";
import { useRunOnce } from "$app/components/useRunOnce";

type SellerAnalytics = {
  seller_id: string;
  analytics: AnalyticsData;
  has_universal_third_party_analytics: boolean;
  username: string | null;
};

type ShowPageProps = React.ComponentProps<typeof Profile> & { seller_analytics: SellerAnalytics };

function UsersShow() {
  const profileProps = typia.assert<ShowPageProps>(usePage().props);
  const addProfileThirdPartyAnalytics = useAddProfileThirdPartyAnalytics();

  // The seller's analytics never fired on the profile: startTrackingForSeller
  // is otherwise only called from product/checkout surfaces (#5676). Tracking
  // fires here — the public page — rather than inside the Profile component,
  // which the profile editor also renders as a preview. Page-view + pixel init
  // only: a profile has no buy action, so no e-commerce events. Enablement is
  // still gated by the gr:*:enabled meta tags inside the tracking modules.
  useRunOnce(() => {
    const { seller_id, analytics, has_universal_third_party_analytics, username } = profileProps.seller_analytics;
    startTrackingForSeller(seller_id, analytics);
    trackProfilePageView(seller_id);
    if (has_universal_third_party_analytics && username != null) addProfileThirdPartyAnalytics({ username });
  });

  return <Profile {...profileProps} />;
}

UsersShow.loggedInUserLayout = true;

export default UsersShow;
