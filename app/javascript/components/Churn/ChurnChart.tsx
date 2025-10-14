import { format, parseISO } from "date-fns";
import * as React from "react";
import { XAxis, YAxis, Line, Area } from "recharts";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

type ChurnDailyData = {
  date: string;
  customer_churn_rate: number;
  churned_subscribers: number;
  churned_mrr_cents: number;
};

import useChartTooltip from "$app/components/Analytics/useChartTooltip";
import { Chart, xAxisProps, yAxisProps, lineProps } from "$app/components/Chart";

type DataPoint = {
  date: string;
  dateFormatted: string;
  churnRate: number;
  cancellations: number;
  revenueLost: number;
  label: string;
};

const ChartTooltip = ({ data }: { data: DataPoint }) => (
  <>
    <div>
      <strong>{data.churnRate.toFixed(1)}%</strong> churn
    </div>
    <div>
      <strong>{data.cancellations}</strong> {data.cancellations === 1 ? "cancellation" : "cancellations"}
    </div>
    <div>
      <strong>
        {formatPriceCentsWithCurrencySymbol("usd", data.revenueLost, {
          symbolFormat: "short",
          noCentsIfWhole: true,
        })}
      </strong>{" "}
      revenue lost
    </div>
    <time className="block font-bold">{data.dateFormatted}</time>
  </>
);

export const ChurnChart = ({ data }: { data: ChurnDailyData[] }) => {
  const dataPoints = React.useMemo(
    () =>
      data.map((item, index) => {
        const date = parseISO(item.date);
        const isFirst = index === 0;
        const isLast = index === data.length - 1;

        return {
          date: item.date,
          dateFormatted: format(date, "EEEE, MMMM do"),
          churnRate: item.customer_churn_rate,
          cancellations: item.churned_subscribers,
          revenueLost: item.churned_mrr_cents,
          label: isFirst || isLast ? format(date, "MMM d") : "",
        };
      }),
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
