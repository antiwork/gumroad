import * as React from "react";
import { Area, Line, XAxis, YAxis } from "recharts";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import useChartTooltip from "$app/components/Analytics/useChartTooltip";
import { Chart, type DotProps, lineProps, xAxisProps, yAxisProps } from "$app/components/Chart";

export type DataPoint = {
  date: string;
  label: string;
  title: string;
  churnRate: number;
  churnedCustomers: number;
  revenueLostCents: number;
};

const ChartTooltip = ({ data }: { data: DataPoint }) => (
  <>
    <div>
      <strong>{data.churnRate.toFixed(2)}%</strong> churn
    </div>
    <div>
      <strong>{data.churnedCustomers}</strong> {data.churnedCustomers === 1 ? "cancellation" : "cancellations"}
    </div>
    <div>
      <strong>
        {formatPriceCentsWithCurrencySymbol("usd", data.revenueLostCents, {
          symbolFormat: "short",
          noCentsIfWhole: true,
        })}
      </strong>{" "}
      revenue lost
    </div>
    <time className="block font-bold">{data.title}</time>
  </>
);

export const ChurnChart = ({ data }: { data: DataPoint[] }) => {
  const { tooltip, containerRef, dotRef, events } = useChartTooltip();
  const tooltipData = tooltip ? data[tooltip.index] : null;

  const hasNonZero = data.some((point) => point.churnRate > 0);
  const yDomain: [number, number | "dataMax"] = hasNonZero ? [0, "dataMax"] : [0, 1];

  return (
    <Chart
      containerRef={containerRef}
      tooltip={tooltipData ? <ChartTooltip data={tooltipData} /> : null}
      tooltipPosition={tooltip?.position ?? null}
      data={data}
      maxBarSize={40}
      margin={{ top: 32, right: 0, bottom: 16, left: 16 }}
      {...events}
    >
      <XAxis {...xAxisProps} dataKey="label" />
      <YAxis {...yAxisProps} domain={yDomain} tickFormatter={(value: number) => `${Number(value.toFixed(2))}%`} />
      <Area dataKey="churnRate" fill="rgb(var(--info))" fillOpacity={0.15} stroke="none" isAnimationActive={false} />
      <Line
        {...lineProps(dotRef, data.length)}
        dataKey="churnRate"
        stroke="rgb(var(--info))"
        dot={({ key, cx, cy, width }: DotProps) => (
          <circle
            ref={dotRef}
            key={key}
            cx={cx}
            cy={cy}
            r={Math.min(width / data.length / 7, 8)}
            fill="rgb(var(--info))"
            data-testid="chart-dot"
          />
        )}
      />
    </Chart>
  );
};
