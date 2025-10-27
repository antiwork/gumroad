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
  daysInPeriod?: number;
};

export const ChurnChart = ({ data, aggregateBy }: { data: ChurnDailyData[]; aggregateBy: "daily" | "monthly" }) => {
  const dataPoints = React.useMemo(() => {
    const dataPoints: DataPoint[] = [];

    data.forEach(
      (
        { date, month, month_index: monthIndex, customer_churn_rate, churned_subscribers, churned_mrr_cents },
        index,
      ) => {
        const parsedDate = parseISO(date);
        const label = index === 0 || index === data.length - 1 ? format(parsedDate, "MMM d") : "";

        if (aggregateBy === "monthly") {
          dataPoints[monthIndex] = {
            date,
            dateFormatted: month,
            churnRate: (dataPoints[monthIndex]?.churnRate || 0) + customer_churn_rate,
            cancellations: (dataPoints[monthIndex]?.cancellations || 0) + churned_subscribers,
            revenueLost: (dataPoints[monthIndex]?.revenueLost || 0) + churned_mrr_cents,
            label: dataPoints[monthIndex]?.label || label,
            daysInPeriod: (dataPoints[monthIndex]?.daysInPeriod || 0) + 1,
          };
        } else {
          dataPoints.push({
            date,
            dateFormatted: format(parsedDate, "EEEE, MMMM do"),
            churnRate: customer_churn_rate,
            cancellations: churned_subscribers,
            revenueLost: churned_mrr_cents,
            label,
          });
        }
      },
    );

    return dataPoints.map((dataPoint) => ({
      ...dataPoint,
      churnRate: dataPoint.daysInPeriod ? dataPoint.churnRate / dataPoint.daysInPeriod : dataPoint.churnRate,
    }));
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
