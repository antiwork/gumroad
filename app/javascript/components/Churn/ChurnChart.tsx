import { format, parseISO } from "date-fns";
import * as React from "react";
import { XAxis, YAxis, Line, Area } from "recharts";

import useChartTooltip from "$app/components/Analytics/useChartTooltip";
import { Chart, xAxisProps, yAxisProps, lineProps } from "$app/components/Chart";

import ChartTooltip from "./ChartTooltip";

type ChurnDailyData = {
  date: string;
  month: string;
  month_index: number;
  customer_churn_rate: number;
  churned_subscribers: number;
  churned_mrr_cents: number;
};

type DataPoint = {
  date: string;
  dateFormatted: string;
  churnRate: number;
  cancellations: number;
  revenueLost: number;
  label: string;
  dailyRates?: number[];
};

export const ChurnChart = ({ data, aggregateBy }: { data: ChurnDailyData[]; aggregateBy: "daily" | "monthly" }) => {
  const dataPoints = React.useMemo(() => {
    const points: DataPoint[] = [];

    data.forEach((item, index) => {
      const date = parseISO(item.date);
      const isFirst = index === 0;
      const isLast = index === data.length - 1;
      const label = isFirst || isLast ? format(date, "MMM d") : "";

      if (aggregateBy === "monthly") {
        const monthIndex = item.month_index;
        if (!points[monthIndex]) {
          points[monthIndex] = {
            date: item.date,
            dateFormatted: item.month,
            churnRate: item.customer_churn_rate,
            cancellations: item.churned_subscribers,
            revenueLost: item.churned_mrr_cents,
            label,
          };
        } else {
          points[monthIndex].churnRate = Math.max(points[monthIndex].churnRate, item.customer_churn_rate);
          points[monthIndex].cancellations += item.churned_subscribers;
          points[monthIndex].revenueLost += item.churned_mrr_cents;
        }
      } else {
        // Daily view
        points.push({
          date: item.date,
          dateFormatted: format(date, "EEEE, MMMM do"),
          churnRate: item.customer_churn_rate,
          cancellations: item.churned_subscribers,
          revenueLost: item.churned_mrr_cents,
          label,
        });
      }
    });

    return points;
  }, [data, aggregateBy]);

  const { tooltip, containerRef, dotRef, events } = useChartTooltip();
  const tooltipData = tooltip ? dataPoints[tooltip.index] : null;

  return (
    <Chart
      containerRef={containerRef}
      tooltip={tooltipData ? <ChartTooltip data={tooltipData} /> : null}
      tooltipPosition={tooltip?.position ?? null}
      data={dataPoints}
      maxBarSize={40}
      margin={{ top: 16, right: 16, bottom: 16, left: 16 }}
      {...events}
    >
      <XAxis {...xAxisProps} dataKey="label" />
      <YAxis {...yAxisProps} domain={[0, "dataMax"]} width={40} tickFormatter={(value) => `${value}%`} />
      <Area type="monotone" dataKey="churnRate" stroke="#000" fill="#90A8ED" fillOpacity={0.3} strokeWidth={2} />
      <Line
        {...lineProps(dotRef, dataPoints.length)}
        dataKey="churnRate"
        stroke="#90A8ED"
        dot={(props: { key: string; cx: number; cy: number; width: number }) => (
          <circle
            ref={dotRef}
            key={props.key}
            cx={props.cx}
            cy={props.cy}
            r={Math.min(props.width / dataPoints.length / 7, 8)}
            fill="#90A8ED"
            stroke="none"
          />
        )}
      />
    </Chart>
  );
};
