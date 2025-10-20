import * as React from "react";
import { XAxis, YAxis, Line } from "recharts";

import { AudienceDataByDate } from "$app/data/audience";

import useChartTooltip from "$app/components/Analytics/useChartTooltip";
import { Chart, lineProps, xAxisProps, yAxisProps } from "$app/components/Chart";

type DataPoint = {
  newFollowers: number;
  followersRemoved: number;
  total: number;
  title: string;
  label: string;
};

const ChartTooltip = ({ data: { newFollowers, followersRemoved, total, title } }: { data: DataPoint }) => (
  <>
    <div>
      <strong>{newFollowers}</strong> new {newFollowers === 1 ? "follower" : "followers"}
    </div>
    {followersRemoved > 0 ? (
      <div>
        <strong>{followersRemoved}</strong> {followersRemoved === 1 ? "follower" : "followers"} removed
      </div>
    ) : null}
    {total > 0 ? (
      <div>
        <strong>{total}</strong> total {total === 1 ? "follower" : "followers"}
      </div>
    ) : null}
    <time className="block font-bold">{title}</time>
  </>
);

export const AudienceChart = ({ data }: { data: AudienceDataByDate }) => {
  const dataPoints = React.useMemo(
    () =>
      data.dates.map(
        (date, index) =>
          ({
            title: date,
            label: index === 0 ? data.start_date : index === data.dates.length - 1 ? data.end_date : "",
            newFollowers: data.by_date.new_followers[index] || 0,
            followersRemoved: data.by_date.followers_removed[index] || 0,
            total: data.by_date.totals[index] || 0,
          }) satisfies DataPoint,
      ),
    [data],
  );

  const { tooltip, containerRef, dotRef, events } = useChartTooltip();
  const tooltipData = tooltip ? dataPoints[tooltip.index] : null;

  return (
    <Chart
      containerRef={containerRef}
      tooltip={tooltipData ? <ChartTooltip data={tooltipData} /> : null}
      tooltipPosition={tooltip?.position ?? null}
      data={dataPoints}
      {...events}
    >
      <XAxis {...xAxisProps} dataKey="label" />
      <YAxis {...yAxisProps} orientation="left" tick={false} width={40} />
      {/* Placeholder y-axis to add a border on the right-hand side of the chart */}
      <YAxis {...yAxisProps} orientation="right" yAxisId="rightPlaceholder" tick={false} width={40} domain={[0, 1]} />
      <Line {...lineProps(dotRef, dataPoints.length)} dataKey="total" />
    </Chart>
  );
};
