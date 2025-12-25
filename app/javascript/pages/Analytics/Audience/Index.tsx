import { Deferred, router, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { AudienceIndexPageProps } from "$app/data/audience";

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { useAnalyticsDateRange } from "$app/components/Analytics/useAnalyticsDateRange";
import { AudienceChart } from "$app/components/Audience/AudienceChart";
import { AudienceQuickStats } from "$app/components/Audience/AudienceQuickStats";
import { Button } from "$app/components/Button";
import { DateRangePicker } from "$app/components/DateRangePicker";
import { ExportSubscribersPopover } from "$app/components/Followers/ExportSubscribersPopover";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Popover } from "$app/components/Popover";
import Placeholder from "$app/components/ui/Placeholder";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/audience.png";

export default function Audience() {
  const { total_follower_count, audience_data } = cast<AudienceIndexPageProps>(usePage().props);
  const dateRange = useAnalyticsDateRange(() => {
    router.reload({ only: ["audience_data"] });
  });
  const hasContent = total_follower_count > 0;

  return (
    <AnalyticsLayout
      title="Analytics"
      selectedTab="following"
      showTabs
      actions={
        hasContent ? (
          <>
            <Popover
              aria-label="Export"
              trigger={
                <WithTooltip tip="Export" position="bottom">
                  <Button aria-label="Export">
                    <Icon aria-label="Download" name="download" />
                  </Button>
                </WithTooltip>
              }
            >
              {(close) => <ExportSubscribersPopover closePopover={close} />}
            </Popover>
            <DateRangePicker {...dateRange} />
          </>
        ) : null
      }
    >
      {hasContent ? (
        <div className="space-y-8 p-4 md:p-8">
          <AudienceQuickStats
            totalFollowers={total_follower_count}
            newFollowers={audience_data?.new_followers ?? null}
          />
          <Deferred
            data="audience_data"
            fallback={
              <div className="input">
                <LoadingSpinner />
                Loading charts...
              </div>
            }
          >
            {audience_data ? <AudienceChart data={audience_data} /> : null}
          </Deferred>
        </div>
      ) : (
        <div className="p-4 md:p-8">
          <Placeholder>
            <figure>
              <img src={placeholder} />
            </figure>
            <h2>It's quiet. Too quiet.</h2>
            <p>
              You don't have any followers yet. Once you do, you'll see them here, along with powerful data that can
              help you keep your growing audience engaged.
            </p>
            <a href="/help/article/170-audience" target="_blank" rel="noreferrer">
              Learn more
            </a>
          </Placeholder>
        </div>
      )}
    </AnalyticsLayout>
  );
}
