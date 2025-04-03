import * as React from "react";

import { Icon } from "$app/components/Icons";
import { Stats } from "$app/components/Stats";
import { useUserAgentInfo } from "$app/components/UserAgent";

export const AudienceQuickStats = ({
  totalFollowers,
  newFollowers,
}: {
  totalFollowers: number;
  newFollowers: number | null;
}) => {
  const userAgentInfo = useUserAgentInfo();

  return (
    <div className="stats-grid">
      <Stats
        className="total-followers"
        title={
          <>
            <Icon name="circle-fill" style={{ color: "rgb(var(--accent))" }} />
            Lifetime followers
            <div className="legend" />
          </>
        }
        value={newFollowers != null ? totalFollowers.toLocaleString(userAgentInfo.locale) : ""}
      />
      <Stats
        className="new-followers"
        title={
          <>
            <Icon name="circle-fill" style={{ color: "rgb(var(--color) / var(--gray-1))" }} />
            New followers
            <div className="legend" />
          </>
        }
        value={newFollowers != null ? newFollowers.toLocaleString(userAgentInfo.locale) : ""}
      />
    </div>
  );
};
