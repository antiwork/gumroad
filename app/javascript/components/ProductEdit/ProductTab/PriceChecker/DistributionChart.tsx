import * as React from "react";
import { Bar, BarChart, Cell, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";

import type { PriceDistributionHistogram, PriceDistributionSummary } from "$app/data/price_distribution";
import type { CurrencyCode } from "$app/utils/currency";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

const PLACEHOLDER_BIN_COUNT = 12;
const PLACEHOLDER_HEIGHT = 1;
const PLACEHOLDER_INTERVAL = 1000;
const MAX_X_TICKS = 6;
const LABEL_FONT_SIZE = 13;
const LINE_GAP = 2;
const PAD_X = 4;
const PAD_Y = 3;
const EDGE_THRESHOLD = 0.05;
const PLACEHOLDER_MIN_OPACITY = 0.01;
const PLACEHOLDER_MAX_OPACITY = 0.08;
const PLACEHOLDER_TOP_RESERVE = 4;
const REAL_TOP_BREATHING = 4;
const LABEL_GAP = 16;

const fmtShort = (currencyCode: CurrencyCode, cents: number) =>
  formatPriceCentsWithCurrencySymbol(currencyCode, cents, { symbolFormat: "short" });

const fmtPrecise = (currencyCode: CurrencyCode, cents: number) =>
  formatPriceCentsWithCurrencySymbol(currencyCode, cents, { symbolFormat: "short", noCentsIfWhole: false });

type ChartRow = {
  key: number;
  midpoint: number;
  count: number;
  fromCents: number;
  toCents: number;
};

type TooltipPayload = { payload: ChartRow };

const ChartTooltip = ({
  active,
  payload,
  currencyCode,
}: {
  active?: boolean;
  payload?: TooltipPayload[];
  currencyCode: CurrencyCode;
}) => {
  const row = payload?.[0]?.payload;
  if (!active || !row) return null;
  return (
    <div className="rounded border border-border bg-background p-2 text-xs text-foreground shadow">
      <div className="font-semibold">
        {fmtShort(currencyCode, row.fromCents)} – {fmtShort(currencyCode, row.toCents)}
      </div>
      <div className="text-muted">
        {row.count} {row.count === 1 ? "product" : "products"}
      </div>
    </div>
  );
};

const buildPlaceholderData = (): ChartRow[] =>
  Array.from({ length: PLACEHOLDER_BIN_COUNT }, (_, i) => ({
    key: i,
    midpoint: i * PLACEHOLDER_INTERVAL + PLACEHOLDER_INTERVAL / 2,
    count: PLACEHOLDER_HEIGHT,
    fromCents: i * PLACEHOLDER_INTERVAL,
    toCents: (i + 1) * PLACEHOLDER_INTERVAL,
  }));

const buildRealData = (histogram: PriceDistributionHistogram): ChartRow[] =>
  histogram.bins.map((bin, i) => ({
    key: i,
    midpoint: (bin.from_cents + bin.to_cents) / 2,
    count: bin.count,
    fromCents: bin.from_cents,
    toCents: bin.to_cents,
  }));

const computeTicks = (rows: ChartRow[]): number[] => {
  if (rows.length === 0) return [];
  const last = rows[rows.length - 1];
  if (!last) return [];
  const edges: number[] = rows.map((r) => r.fromCents);
  edges.push(last.toCents);
  if (edges.length <= MAX_X_TICKS) return edges;
  const step = Math.ceil(edges.length / MAX_X_TICKS);
  const sampled: number[] = edges.filter((_, i) => i % step === 0);
  const finalEdge = edges[edges.length - 1] ?? 0;
  if (sampled[sampled.length - 1] !== finalEdge) sampled.push(finalEdge);
  return sampled;
};

const approxLabelWidth = (lines: string[]) => {
  const longest = lines.reduce((acc, l) => Math.max(acc, l.length), 0);
  return Math.max(50, longest * (LABEL_FONT_SIZE * 0.65) + PAD_X * 2);
};

const labelHeight = (lineCount: number) => lineCount * LABEL_FONT_SIZE + (lineCount - 1) * LINE_GAP + PAD_Y * 2;

const computeXShift = (value: number, min: number, max: number, halfWidth: number) => {
  const range = max - min;
  if (range <= 0) return 0;
  const t = (value - min) / range;
  if (t <= EDGE_THRESHOLD) return halfWidth;
  if (t >= 1 - EDGE_THRESHOLD) return -halfWidth;
  return 0;
};

const placeholderOpacity = (index: number, total: number) => {
  if (total <= 1) return PLACEHOLDER_MAX_OPACITY;
  const middle = (total - 1) / 2;
  const distance = Math.abs(index - middle) / middle;
  return PLACEHOLDER_MIN_OPACITY + (PLACEHOLDER_MAX_OPACITY - PLACEHOLDER_MIN_OPACITY) * distance;
};

type RefLineLabelProps = {
  viewBox?: { x?: number; y?: number; width?: number; height?: number };
  title: string;
  value?: string;
  fillColor: string;
  textColor: string;
  yOffset?: number;
  xShift?: number;
  partialLineColor?: string;
};

const RefLineLabel: React.FC<RefLineLabelProps> = ({
  viewBox,
  title,
  value,
  fillColor,
  textColor,
  yOffset = 0,
  xShift = 0,
  partialLineColor,
}) => {
  if (!viewBox || viewBox.x === undefined || viewBox.y === undefined) return null;
  const lines = value !== undefined ? [title, value] : [title];
  const width = approxLabelWidth(lines);
  const height = labelHeight(lines.length);
  const cx = viewBox.x + xShift;
  const top = viewBox.y - height + yOffset;
  const labelCenterY = top + height / 2;
  const plotBottom = viewBox.y + (viewBox.height ?? 0);
  const lineYs = lines.map((_, i) => top + PAD_Y + LABEL_FONT_SIZE / 2 + i * (LABEL_FONT_SIZE + LINE_GAP));
  return (
    <g pointerEvents="none">
      {partialLineColor ? (
        <line
          x1={viewBox.x}
          x2={viewBox.x}
          y1={labelCenterY}
          y2={plotBottom}
          stroke={partialLineColor}
          strokeWidth={2}
          strokeDasharray="4 4"
        />
      ) : null}
      <rect x={cx - width / 2} y={top} width={width} height={height} rx={3} fill={fillColor} stroke="none" />
      {lines.map((line, i) => (
        <text
          key={i}
          x={cx}
          y={lineYs[i]}
          fill={textColor}
          fontSize={LABEL_FONT_SIZE}
          textAnchor="middle"
          dominantBaseline="central"
          style={i === 1 ? { fontVariantNumeric: "tabular-nums" } : undefined}
        >
          {line}
        </text>
      ))}
    </g>
  );
};

export const DistributionChart = ({
  mode,
  histogram,
  summary,
  currencyCode,
  currentPriceCents,
}: {
  mode: "placeholder" | "real";
  histogram: PriceDistributionHistogram | null;
  summary: PriceDistributionSummary | null;
  currencyCode: CurrencyCode;
  currentPriceCents: number;
}) => {
  const animatedOnceRef = React.useRef(false);
  const isFirstRealRender = mode === "real" && !animatedOnceRef.current;
  React.useEffect(() => {
    if (mode === "real") animatedOnceRef.current = true;
  });

  const [hoveredIndex, setHoveredIndex] = React.useState<number | null>(null);

  const data: ChartRow[] = mode === "real" && histogram ? buildRealData(histogram) : buildPlaceholderData();
  const showAxis = mode === "real";
  const ticks: number[] = showAxis ? computeTicks(data) : [];

  const minBin = data[0]?.fromCents ?? 0;
  const maxBin = data[data.length - 1]?.toCents ?? PLACEHOLDER_INTERVAL * PLACEHOLDER_BIN_COUNT;
  const domain: [number, number] = [minBin, maxBin];

  const yourPriceLines = ["Your price"];
  const yourPriceWidth = approxLabelWidth(yourPriceLines);
  const yourPriceHeight = labelHeight(yourPriceLines.length);
  const yourPriceShift = computeXShift(currentPriceCents, minBin, maxBin, yourPriceWidth / 2);

  const medianValueText = summary ? fmtPrecise(currencyCode, summary.median_cents) : "";
  const medianLines = summary ? ["Median", medianValueText] : ["Median"];
  const medianHeight = labelHeight(medianLines.length);
  const medianWidth = approxLabelWidth(medianLines);
  const medianShift = summary ? computeXShift(summary.median_cents, minBin, maxBin, medianWidth / 2) : 0;
  const medianYOffset = medianHeight + LABEL_GAP;
  const topReserve = mode === "real" ? yourPriceHeight + REAL_TOP_BREATHING : PLACEHOLDER_TOP_RESERVE;

  return (
    <ResponsiveContainer width="100%" aspect={2.4}>
      <BarChart
        data={data}
        margin={{
          top: topReserve,
          right: mode === "placeholder" ? 0 : 4,
          bottom: 0,
          left: mode === "placeholder" ? 0 : 4,
        }}
        onMouseMove={(state: { activeTooltipIndex?: number; isTooltipActive?: boolean }) => {
          if (mode !== "real") return;
          if (state.isTooltipActive && typeof state.activeTooltipIndex === "number") {
            setHoveredIndex(state.activeTooltipIndex);
          } else {
            setHoveredIndex(null);
          }
        }}
        onMouseLeave={() => setHoveredIndex(null)}
      >
        <XAxis
          type="number"
          dataKey="midpoint"
          domain={domain}
          ticks={ticks}
          tickLine={false}
          axisLine={showAxis ? { stroke: "currentColor", opacity: 0.4 } : false}
          tick={showAxis ? { fill: "currentColor", fontSize: 11 } : false}
          tickFormatter={(v: number) => fmtShort(currencyCode, v)}
          height={showAxis ? 22 : 0}
          interval="preserveStartEnd"
          padding={{ left: 0, right: 0 }}
        />
        <YAxis hide />
        {mode === "real" ? <Tooltip cursor={false} content={<ChartTooltip currencyCode={currencyCode} />} /> : null}
        <Bar
          dataKey="count"
          radius={[4, 4, 0, 0]}
          isAnimationActive={isFirstRealRender}
          animationDuration={isFirstRealRender ? 350 : 0}
        >
          {data.map((row, i) => {
            if (mode === "placeholder") {
              return (
                <Cell key={row.key} style={{ fill: `rgb(var(--color) / ${placeholderOpacity(i, data.length)})` }} />
              );
            }
            return <Cell key={row.key} className={hoveredIndex === i ? "fill-accent/60" : "fill-accent/40"} />;
          })}
        </Bar>
        {mode === "real" ? (
          <ReferenceLine
            x={currentPriceCents}
            stroke="var(--color-success)"
            strokeWidth={2}
            strokeDasharray="4 4"
            ifOverflow="extendDomain"
            isFront={false}
          />
        ) : null}
        {mode === "real" && summary ? (
          <ReferenceLine
            x={summary.median_cents}
            stroke="none"
            ifOverflow="extendDomain"
            isFront
            label={
              <RefLineLabel
                title="Median"
                value={medianValueText}
                fillColor="var(--color-foreground)"
                textColor="var(--color-background)"
                yOffset={medianYOffset}
                xShift={medianShift}
                partialLineColor="var(--color-foreground)"
              />
            }
          />
        ) : null}
        {mode === "real" ? (
          <ReferenceLine
            x={currentPriceCents}
            stroke="none"
            ifOverflow="extendDomain"
            isFront
            label={
              <RefLineLabel
                title="Your price"
                fillColor="var(--color-success)"
                textColor="var(--color-success-foreground)"
                xShift={yourPriceShift}
              />
            }
          />
        ) : null}
      </BarChart>
    </ResponsiveContainer>
  );
};
