import * as React from "react";
import { XAxis, YAxis, Line } from "recharts";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import useChartTooltip from "$app/components/Analytics/useChartTooltip";
import { Chart, xAxisProps, yAxisProps, lineProps } from "$app/components/Chart";

type ChurnDataPoint = {
  churn_rate: number;
  cancelled_count: number;
  revenue_lost_cents: number;
  date: string;
  label: string;
  title: string;
};

const ChartTooltip = ({ data }: { data: ChurnDataPoint }) => (
  <>
    <div>
      Churn Rate: <strong>{data.churn_rate.toFixed(2)}%</strong>
    </div>
    <div>
      Churned Users: <strong>{data.cancelled_count}</strong>
    </div>
    {data.revenue_lost_cents > 0 ? (
      <div>
        Revenue Lost:{" "}
        <strong>
          {formatPriceCentsWithCurrencySymbol("usd", data.revenue_lost_cents, {
            symbolFormat: "short",
            noCentsIfWhole: true,
          })}
        </strong>
      </div>
    ) : null}
    <time className="block font-bold">{data.title}</time>
  </>
);

export type ChurnDailyData = {
  date: string;
  month: string;
  monthIndex: number;
  churn_rate: number;
  cancelled_count: number;
  revenue_lost_cents: number;
  active_at_start?: number;
  new_subscriptions?: number;
};

export const ChurnChart = ({
  data,
  startDate,
  endDate,
  aggregateBy,
}: {
  data: ChurnDailyData[];
  startDate: string;
  endDate: string;
  aggregateBy: "monthly" | "daily";
}) => {
  const dataPoints = React.useMemo(() => {
    const dataPoints: ChurnDataPoint[] = [];

    data.forEach(({ churn_rate, cancelled_count, revenue_lost_cents, month, monthIndex, date, active_at_start, new_subscriptions }, index) => {
      const label = index === 0 ? startDate : index === data.length - 1 ? endDate : "";

      if (aggregateBy === "monthly") {
        const existing = dataPoints[monthIndex];
        // For monthly aggregation, recalculate churn rate from base metrics
        if (existing) {
          const totalCancelled = existing.cancelled_count + cancelled_count;
          const totalRevenueLost = existing.revenue_lost_cents + revenue_lost_cents;

          // Properly recalculate monthly churn rate using the formula:
          // (Total Cancelled in Month / (Total Active at Start + Total New in Month)) × 100
          // We need to accumulate these base metrics from daily data
          const totalActive = (existing as any).active_at_start + (active_at_start || 0);
          const totalNew = (existing as any).new_subscriptions + (new_subscriptions || 0);
          const totalBase = totalActive + totalNew;
          const newChurnRate = totalBase > 0 ? (totalCancelled / totalBase * 100) : 0;

          dataPoints[monthIndex] = {
            title: month,
            date: month,
            churn_rate: newChurnRate,
            cancelled_count: totalCancelled,
            revenue_lost_cents: totalRevenueLost,
            label: existing.label || label,
            active_at_start: totalActive,
            new_subscriptions: totalNew,
          } as any;
        } else {
          dataPoints[monthIndex] = {
            title: month,
            date: month,
            churn_rate,
            cancelled_count,
            revenue_lost_cents,
            label,
            active_at_start: active_at_start || 0,
            new_subscriptions: new_subscriptions || 0,
          } as any;
        }
      } else {
        dataPoints.push({
          title: date,
          date,
          churn_rate,
          cancelled_count,
          revenue_lost_cents,
          label,
        });
      }
    });

    return dataPoints;
  }, [data, aggregateBy, startDate, endDate]);

  const { tooltip, containerRef, dotRef, events } = useChartTooltip();
  const tooltipData = tooltip ? dataPoints[tooltip.index] : null;

  // Calculate max churn rate for Y-axis scaling
  const maxChurnRate = Math.max(...dataPoints.map((d) => d.churn_rate), 10);
  const yAxisMax = Math.ceil(maxChurnRate / 10) * 10; // Round up to nearest 10

  return (
    <Chart
      containerRef={containerRef}
      tooltip={tooltipData ? <ChartTooltip data={tooltipData} /> : null}
      tooltipPosition={tooltip?.position ?? null}
      data={dataPoints}
      {...events}
    >
      <XAxis {...xAxisProps} dataKey="label" />
      <YAxis
        {...yAxisProps}
        orientation="right"
        domain={[0, yAxisMax]}
        tickFormatter={(value: number) => `${value}%`}
      />
      <Line
        {...lineProps}
        ref={dotRef}
        type="monotone"
        dataKey="churn_rate"
        stroke="hsl(var(--error))"
        fill="hsl(var(--error))"
        strokeWidth={2}
      />
    </Chart>
  );
};
