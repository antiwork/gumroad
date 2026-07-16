import * as React from "react";
import { XAxis, YAxis, Bar, Line, Cell, Customized } from "recharts";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { type AnalyticsDailyTotal } from "$app/components/Analytics";
import { fractionOfDayElapsed, projectedEndOfDayTotal } from "$app/components/Analytics/projectedEndOfDayTotal";
import useChartTooltip from "$app/components/Analytics/useChartTooltip";
import { Chart, xAxisProps, yAxisProps, lineProps } from "$app/components/Chart";

type DataPoint = {
  views: number;
  viewsWithoutSales: number;
  sales: number;
  totals: number;
  title: string;
  label: string;
  projectedTotals?: number;
};

// Internal chart state Recharts passes to a `Customized` child: each graphical item
// (our bars and the totals line) with its computed pixel coordinates and axis scales.
// Recharts doesn't export this type, so we describe just the parts we read.
type FormattedGraphicalItem = {
  item?: { props?: { dataKey?: unknown; yAxisId?: unknown } };
  props?: {
    points?: ({ x?: number; y?: number } | null)[];
    yAxis?: { scale?: (value: number) => number };
  };
};

// Draws the projected end-of-day overlay: a dashed, semi-transparent vertical line from
// today's actual total up to the projected total, capped with a dot. Rendered through
// Recharts' `Customized` so we can reuse the pixel coordinates Recharts already computed
// for the totals line's last point — `ReferenceLine`'s categorical `segment` resolution
// produced NaN x-coordinates for this chart (duplicate/empty category labels), so we
// draw the SVG primitives ourselves from known-good coordinates instead.
const ProjectionOverlay = ({
  formattedGraphicalItems,
  projectedTotals,
}: {
  formattedGraphicalItems?: FormattedGraphicalItem[];
  projectedTotals: number;
}) => {
  const totalsLine = formattedGraphicalItems?.find(
    (graphicalItem) => graphicalItem.item?.props?.dataKey === "totals" && graphicalItem.item.props.yAxisId === "totals",
  );
  const lastPoint = totalsLine?.props?.points?.[totalsLine.props.points.length - 1];
  const scale = totalsLine?.props?.yAxis?.scale;
  if (!lastPoint || typeof scale !== "function") return null;
  const { x, y } = lastPoint;
  if (typeof x !== "number" || typeof y !== "number") return null;
  const projectedY = scale(projectedTotals);
  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(projectedY)) return null;
  return (
    <g>
      <line
        x1={x}
        x2={x}
        y1={y}
        y2={projectedY}
        stroke="rgb(var(--accent))"
        strokeOpacity={0.5}
        strokeWidth={2}
        strokeDasharray="4 4"
        data-testid="chart-projection-line"
      />
      <circle
        cx={x}
        cy={projectedY}
        r={4}
        fill="rgb(var(--accent))"
        fillOpacity={0.5}
        stroke="none"
        data-testid="chart-projected-dot"
      />
    </g>
  );
};

const ChartTooltip = ({ data: { views, sales, totals, title, projectedTotals } }: { data: DataPoint }) => (
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
    {projectedTotals != null ? (
      <div>
        {formatPriceCentsWithCurrencySymbol("usd", projectedTotals, { symbolFormat: "short", noCentsIfWhole: true })}{" "}
        projected today
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
  sellerTimeZone,
}: {
  data: AnalyticsDailyTotal[];
  startDate: string;
  endDate: string;
  aggregateBy: "monthly" | "daily";
  sellerTimeZone?: string;
}) => {
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

    return dataPoints.map((dataPoint) => ({
      ...dataPoint,
      viewsWithoutSales: Math.max(0, dataPoint.viewsWithoutSales),
    }));
  }, [data, aggregateBy]);

  // When the range ends today (the backend formats today's date as "Today"), overlay a
  // projected end-of-day total above today's point: current total extrapolated by the
  // fraction of the seller's day elapsed. Rendered as a dashed, semi-transparent
  // extension so it clearly reads as an estimate, not booked revenue.
  const lastDataPoint = dataPoints[dataPoints.length - 1];
  const projection = React.useMemo(() => {
    if (aggregateBy !== "daily" || endDate !== "Today" || !sellerTimeZone || !lastDataPoint) return null;
    const projectedTotals = projectedEndOfDayTotal(lastDataPoint.totals, fractionOfDayElapsed(sellerTimeZone));
    if (projectedTotals === null || projectedTotals <= lastDataPoint.totals) return null;
    return { projectedTotals };
  }, [aggregateBy, endDate, sellerTimeZone, lastDataPoint]);

  const dataPointsWithProjection = React.useMemo(
    () =>
      projection
        ? dataPoints.map((dataPoint, index) =>
            index === dataPoints.length - 1 ? { ...dataPoint, projectedTotals: projection.projectedTotals } : dataPoint,
          )
        : dataPoints,
    [dataPoints, projection],
  );

  const { tooltip, containerRef, dotRef, events } = useChartTooltip();
  const tooltipData = tooltip ? dataPointsWithProjection[tooltip.index] : null;

  return (
    <Chart
      containerRef={containerRef}
      tooltip={tooltipData ? <ChartTooltip data={tooltipData} /> : null}
      tooltipPosition={tooltip?.position ?? null}
      data={dataPointsWithProjection}
      maxBarSize={40}
      margin={{ top: 32, right: 0, bottom: 16, left: 16 }}
      {...events}
    >
      <XAxis {...xAxisProps} dataKey="label" />
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
      {projection ? (
        <>
          {/* Invisible series whose only purpose is to include the projected value in the
              totals axis domain, so the overlay's dot never lands above the plot area
              (this replaces ReferenceLine's ifOverflow="extendDomain" behavior). */}
          <Line
            dataKey="projectedTotals"
            yAxisId="totals"
            stroke="none"
            dot={false}
            activeDot={false}
            isAnimationActive={false}
          />
          <Customized
            key={`projection-${projection.projectedTotals}`}
            component={<ProjectionOverlay projectedTotals={projection.projectedTotals} />}
          />
        </>
      ) : null}
    </Chart>
  );
};
