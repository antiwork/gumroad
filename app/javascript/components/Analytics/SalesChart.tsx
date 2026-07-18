import * as React from "react";
import { XAxis, YAxis, Bar, Line, Cell } from "recharts";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { type AnalyticsDailyTotal } from "$app/components/Analytics";
import useChartTooltip from "$app/components/Analytics/useChartTooltip";
import { Chart, xAxisProps, yAxisProps, lineProps, type TickProps } from "$app/components/Chart";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";

// Hourly bucket titles come from D3.hour_month_domain on the backend, always in the
// shape "Friday, July 16th, 1 PM". Parse out the pieces we need for axis ticks.
const parseHourlyTitle = (title: string) => {
  const match = /^\w+, (\w+) (\d+)\w*, (\d{1,2} [AP]M)$/u.exec(title);
  if (!match) return null;
  const [, month = "", day = "", hour = ""] = match;
  return { hour, dayKey: `${month} ${day}`, shortDate: `${month.slice(0, 3)} ${day}` };
};

// Candidate sets of wall-clock hours to label, from densest to sparsest. We pick the
// densest one that still fits the available width for the selected number of days.
const HOUR_TICK_PRESETS = [["12 AM", "6 AM", "12 PM", "6 PM"], ["12 AM", "12 PM"], ["12 AM"]];

// Overwrites each point's axis label for the hourly view: a few time ticks per day
// (e.g. "6 AM", "12 PM"), with a short date ("Jul 17") at each day boundary when the
// range spans multiple days. Labels thin out as the range grows or the screen narrows.
const applyHourlyLabels = (dataPoints: DataPoint[], maxTicks: number) => {
  const parsed = dataPoints.map((point) => parseHourlyTitle(point.title));
  const dayCount = Math.max(new Set(parsed.flatMap((info) => (info ? [info.dayKey] : []))).size, 1);
  const hourTicks = HOUR_TICK_PRESETS.find((preset) => dayCount * preset.length <= maxTicks) ?? ["12 AM"];
  // When even one label per day is too many (long ranges on narrow screens), label every Nth day.
  const dayStride = Math.max(1, Math.ceil(dayCount / maxTicks));

  let lastDayKey: string | null = null;
  let dayIndex = -1;
  parsed.forEach((info, index) => {
    const point = dataPoints[index];
    if (!point) return;
    if (!info) {
      point.label = "";
      return;
    }
    // Day boundaries are detected by the date changing (not by "12 AM") so that DST
    // days whose first bucket isn't midnight still get their date label.
    const isNewDay = info.dayKey !== lastDayKey;
    if (isNewDay) {
      lastDayKey = info.dayKey;
      dayIndex += 1;
    }
    if (dayIndex % dayStride !== 0) point.label = "";
    else if (dayCount > 1 && isNewDay) point.label = info.shortDate;
    else point.label = hourTicks.includes(info.hour) && (!isNewDay || dayCount === 1) ? info.hour : "";
  });
};

type DataPoint = {
  views: number;
  viewsWithoutSales: number;
  sales: number;
  totals: number;
  title: string;
  label: string;
};

const ChartTooltip = ({ data: { views, sales, totals, title } }: { data: DataPoint }) => (
  <>
    <div>
      <strong>{views}</strong> {views === 1 ? "view" : "views"}
    </div>
    {sales > 0 ? (
      <div>
        <strong>{sales}</strong> {sales === 1 ? "sale" : "sales"}
      </div>
    ) : null}
    {views > 0 && sales > 0 ? <div>({Math.round((sales / views) * 1000) / 10}% conversion)</div> : null}
    {totals > 0 ? (
      <div>
        <strong>
          {formatPriceCentsWithCurrencySymbol("usd", totals, { symbolFormat: "short", noCentsIfWhole: true })}
        </strong>
      </div>
    ) : null}
    <time className="block font-bold">{title}</time>
  </>
);

export const SalesChart = ({
  data,
  startDate,
  endDate,
  aggregateBy,
}: {
  data: AnalyticsDailyTotal[];
  startDate: string;
  endDate: string;
  aggregateBy: "monthly" | "daily" | "hourly";
}) => {
  const isDesktop = useIsAboveBreakpoint("lg");
  // Roughly how many x-axis labels fit without crowding; hourly labels are short
  // ("6 AM", "Jul 17") so mobile can still take a handful.
  const maxHourlyTicks = isDesktop ? 28 : 8;
  const dataPoints = React.useMemo(() => {
    const dataPoints: DataPoint[] = [];

    data.forEach(({ views, sales, totals, month, monthIndex, date }, index) => {
      const label = index === 0 ? startDate : index === data.length - 1 ? endDate : "";

      if (aggregateBy === "monthly") {
        dataPoints[monthIndex] = {
          title: month,
          views: (dataPoints[monthIndex]?.views || 0) + views,
          viewsWithoutSales: (dataPoints[monthIndex]?.viewsWithoutSales || 0) + (views - sales),
          sales: (dataPoints[monthIndex]?.sales || 0) + sales,
          totals: (dataPoints[monthIndex]?.totals || 0) + totals,
          label: dataPoints[monthIndex]?.label || label,
        };
      } else {
        dataPoints.push({ title: date, views, viewsWithoutSales: views - sales, sales, totals, label });
      }
    });

    if (aggregateBy === "hourly") applyHourlyLabels(dataPoints, maxHourlyTicks);

    return dataPoints.map((dataPoint) => ({
      ...dataPoint,
      viewsWithoutSales: Math.max(0, dataPoint.viewsWithoutSales),
    }));
  }, [data, aggregateBy, maxHourlyTicks]);

  const { tooltip, containerRef, dotRef, events } = useChartTooltip();
  const tooltipData = tooltip ? dataPoints[tooltip.index] : null;

  return (
    <Chart
      containerRef={containerRef}
      tooltip={tooltipData ? <ChartTooltip data={tooltipData} /> : null}
      tooltipPosition={tooltip?.position ?? null}
      data={dataPoints}
      maxBarSize={40}
      margin={{ top: 32, right: 0, bottom: 16, left: 16 }}
      {...events}
    >
      <XAxis
        {...xAxisProps}
        dataKey="label"
        // Hourly mode sets its own sparse labels on mid-range points, which recharts'
        // default "preserveStartEnd" interval would drop — render every tick instead
        // (blank labels take no space) and center the mid-range ones under their bars.
        {...(aggregateBy === "hourly"
          ? {
              interval: 0 as const,
              tick: ({ x, y, payload }: TickProps) => (
                <text
                  x={x}
                  y={y}
                  dy={16}
                  textAnchor={
                    payload.index === 0 ? "start" : payload.index === dataPoints.length - 1 ? "end" : "middle"
                  }
                  fill="currentColor"
                >
                  {payload.value}
                </text>
              ),
            }
          : {})}
      />
      <YAxis {...yAxisProps} orientation="right" tickFormatter={(value: number) => value.toLocaleString()} />
      <YAxis
        {...yAxisProps}
        yAxisId="totals"
        orientation="left"
        tickFormatter={(value: number) =>
          formatPriceCentsWithCurrencySymbol("usd", value, {
            symbolFormat: "short",
            noCentsIfWhole: true,
          })
        }
      />
      <Bar dataKey="sales" stackId="stack" className="fill-current" data-testid="chart-bar" />
      <Bar dataKey="viewsWithoutSales" stackId="stack" radius={[4, 4, 0, 0]} data-testid="chart-bar">
        {dataPoints.map((_, index) => (
          <Cell key={index} className={tooltip?.index === index ? "fill-foreground/20" : "fill-foreground/10"} />
        ))}
      </Bar>
      <Line {...lineProps(dotRef, dataPoints.length)} dataKey="totals" yAxisId="totals" />
    </Chart>
  );
};
