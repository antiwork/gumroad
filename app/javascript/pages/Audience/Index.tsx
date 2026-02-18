import { Deferred, router, usePage } from "@inertiajs/react";
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
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { useOnChange } from "$app/components/useOnChange";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/audience.png";

interface AudiencePageProps {
  total_follower_count: number;
  audience_data?: AudienceDataByDate | null;
}

function Audience() {
  const { total_follower_count, audience_data } = cast<AudiencePageProps>(usePage().props);
  const dateRange = useAnalyticsDateRange();
  const startTime = lightFormat(dateRange.from, "yyyy-MM-dd");
  const endTime = lightFormat(dateRange.to, "yyyy-MM-dd");

  const hasContent = total_follower_count > 0;

  useOnChange(() => {
    if (!hasContent) return;
    router.reload({ only: ["audience_data"], data: { from: startTime, to: endTime } });
  }, [hasContent, startTime, endTime]);

  return (
    <AnalyticsLayout
      selectedTab="following"
      actions={
        hasContent ? (
          <div className="flex w-full gap-2">
            <Popover>
              <PopoverAnchor>
                <WithTooltip tip="Export" position="bottom">
                  <PopoverTrigger aria-label="Export" asChild>
                    <Button>
                      <Icon aria-label="Download" name="download" />
                    </Button>
                  </PopoverTrigger>
                </WithTooltip>
              </PopoverAnchor>
              <PopoverContent sideOffset={4}>
                <ExportSubscribersPopover />
              </PopoverContent>
            </Popover>
            <div className="flex-1">
              <DateRangePicker {...dateRange} />
            </div>
          </div>
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
            data={["audience_data"]}
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
            <PlaceholderImage src={placeholder} />
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
