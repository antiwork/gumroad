import { router, usePage } from "@inertiajs/react";
import { lightFormat } from "date-fns";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { type AudienceDataByDate } from "$app/data/audience";

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

interface AudiencePageProps {
  total_follower_count: number;
  audience_data?: AudienceDataByDate;
}

function Audience() {
  const { total_follower_count, audience_data } = cast<AudiencePageProps>(usePage().props);
  const dateRange = useAnalyticsDateRange();
  const [loading, setLoading] = React.useState(false);
  const isInitialMount = React.useRef(true);
  const startTime = lightFormat(dateRange.from, "yyyy-MM-dd");
  const endTime = lightFormat(dateRange.to, "yyyy-MM-dd");

  const hasContent = total_follower_count > 0;

  const reloadAudienceData = React.useCallback((start: string, end: string) => {
    router.reload({
      only: ["audience_data"],
      data: { from: start, to: end },
      onStart: () => setLoading(true),
      onFinish: () => setLoading(false),
    });
  }, []);

  React.useEffect(() => {
    if (!hasContent) return;

    if (isInitialMount.current) {
      isInitialMount.current = false;
      return;
    }

    reloadAudienceData(startTime, endTime);
  }, [startTime, endTime, hasContent, reloadAudienceData]);

  return (
    <AnalyticsLayout
      selectedTab="following"
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
          {audience_data && !loading ? (
            <AudienceChart data={audience_data} />
          ) : (
            <div className="input">
              <LoadingSpinner />
              Loading charts...
            </div>
          )}
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

export default Audience;
