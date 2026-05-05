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
const PAD_X_TIGHT = 1;
const PAD_X_COMFORTABLE = 4;
const PAD_Y = 3;
const EDGE_THRESHOLD = 0.1;
const PLACEHOLDER_MIN_OPACITY = 0.01;
const PLACEHOLDER_MAX_OPACITY = 0.08;
const PLACEHOLDER_TOP_RESERVE = 4;
const REAL_TOP_BREATHING = 4;
const LABEL_GAP = 16;
const ESTIMATED_PLOT_WIDTH_PX = 500;
const CLUSTER_BUFFER_RATIO = 0.02;
const CHAR_WIDTH_RATIO = 0.55;
const MIN_LABEL_WIDTH = 30;
const MAX_LABELED_PER_CLUSTER = 4;
const LABEL_RADIUS = 3;
const BASE_FILL = "color-mix(in oklab, var(--color-success), var(--color-foreground) 15%)";
const VARIANT_FILL = "color-mix(in oklab, var(--color-success), var(--color-background) 15%)";

const fmtShort = (currencyCode: CurrencyCode, cents: number) =>
  formatPriceCentsWithCurrencySymbol(currencyCode, cents, { symbolFormat: "short" });

const fmtPrecise = (currencyCode: CurrencyCode, cents: number) =>
  formatPriceCentsWithCurrencySymbol(currencyCode, cents, { symbolFormat: "short", noCentsIfWhole: false });

export type PriceMarker = { id: string; label: string; valueCents: number };

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

const approxLabelWidth = (lines: string[], padX: number = PAD_X_TIGHT) => {
  const longest = lines.reduce((acc, l) => Math.max(acc, l.length), 0);
  return Math.max(MIN_LABEL_WIDTH, longest * (LABEL_FONT_SIZE * CHAR_WIDTH_RATIO) + padX * 2);
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

type CornerOmit = "bl" | "br" | null;

const labelPath = (x: number, y: number, w: number, h: number, r: number, omit: CornerOmit) => {
  const x2 = x + w;
  const y2 = y + h;
  const blR = omit === "bl" ? 0 : r;
  const brR = omit === "br" ? 0 : r;
  return [
    `M ${x + r} ${y}`,
    `H ${x2 - r}`,
    `Q ${x2} ${y} ${x2} ${y + r}`,
    `V ${y2 - brR}`,
    brR ? `Q ${x2} ${y2} ${x2 - brR} ${y2}` : `L ${x2} ${y2}`,
    `H ${x + blR}`,
    blR ? `Q ${x} ${y2} ${x} ${y2 - blR}` : `L ${x} ${y2}`,
    `V ${y + r}`,
    `Q ${x} ${y} ${x + r} ${y}`,
    "Z",
  ].join(" ");
};

type RefLineLabelProps = {
  viewBox?: { x?: number; y?: number; width?: number; height?: number };
  title: string;
  value?: string;
  fillColor: string;
  textColor: string;
  yOffset?: number;
  xShift?: number;
  padX?: number;
};

const RefLineLabel: React.FC<RefLineLabelProps> = ({
  viewBox,
  title,
  value,
  fillColor,
  textColor,
  yOffset = 0,
  xShift = 0,
  padX = PAD_X_TIGHT,
}) => {
  if (!viewBox || viewBox.x === undefined || viewBox.y === undefined) return null;
  const lines = value !== undefined ? [title, value] : [title];
  const width = approxLabelWidth(lines, padX);
  const height = labelHeight(lines.length);
  const cx = viewBox.x + xShift;
  const top = viewBox.y - height + yOffset;
  const lineYs = lines.map((_, i) => top + PAD_Y + LABEL_FONT_SIZE / 2 + i * (LABEL_FONT_SIZE + LINE_GAP));
  const omitCorner: CornerOmit = xShift > 0 ? "bl" : xShift < 0 ? "br" : null;
  return (
    <g pointerEvents="none">
      <path
        d={labelPath(cx - width / 2, top, width, height, LABEL_RADIUS, omitCorner)}
        fill={fillColor}
        stroke="none"
      />
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

type PartialDashedLineProps = {
  viewBox?: { x?: number; y?: number; width?: number; height?: number };
  color: string;
  yOffset?: number;
  labelHeightPx: number;
  fromBottom?: boolean;
};

const PartialDashedLine: React.FC<PartialDashedLineProps> = ({
  viewBox,
  color,
  yOffset = 0,
  labelHeightPx,
  fromBottom = false,
}) => {
  if (!viewBox || viewBox.x === undefined || viewBox.y === undefined) return null;
  const top = viewBox.y - labelHeightPx + yOffset;
  const startY = fromBottom ? top + labelHeightPx : top + labelHeightPx / 2;
  const plotBottom = viewBox.y + (viewBox.height ?? 0);
  return (
    <g pointerEvents="none">
      <line
        x1={viewBox.x}
        x2={viewBox.x}
        y1={startY}
        y2={plotBottom}
        stroke={color}
        strokeWidth={2}
        strokeDasharray="4 4"
      />
    </g>
  );
};

type LayoutMarker = PriceMarker & { stackIndex: number; renderLabel: boolean };

const labelWidthInDomain = (label: string, domainRange: number) =>
  (approxLabelWidth([label]) / ESTIMATED_PLOT_WIDTH_PX) * domainRange;

const layoutMarkers = (markers: PriceMarker[], minBin: number, maxBin: number): LayoutMarker[] => {
  if (markers.length === 0) return [];
  const range = Math.max(1, maxBin - minBin);
  const buffer = range * CLUSTER_BUFFER_RATIO;
  const sorted = [...markers].sort((a, b) => a.valueCents - b.valueCents);
  const clusters: PriceMarker[][] = [];
  for (const marker of sorted) {
    const lastCluster = clusters[clusters.length - 1];
    const lastMember = lastCluster?.[lastCluster.length - 1];
    if (lastCluster && lastMember) {
      const minDistance =
        (labelWidthInDomain(lastMember.label, range) + labelWidthInDomain(marker.label, range)) / 2 + buffer;
      if (marker.valueCents - lastMember.valueCents < minDistance) {
        lastCluster.push(marker);
        continue;
      }
    }
    clusters.push([marker]);
  }
  return clusters.flatMap((cluster) =>
    cluster.map((marker, indexInCluster) => ({
      ...marker,
      stackIndex: indexInCluster,
      renderLabel: indexInCluster < MAX_LABELED_PER_CLUSTER,
    })),
  );
};

export const DistributionChart = ({
  mode,
  histogram,
  summary,
  currencyCode,
  priceMarkers,
}: {
  mode: "placeholder" | "real";
  histogram: PriceDistributionHistogram | null;
  summary: PriceDistributionSummary | null;
  currencyCode: CurrencyCode;
  priceMarkers: PriceMarker[];
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

  const sampleMarkerLines = ["Your price"];
  const markerLabelHeight = labelHeight(sampleMarkerLines.length);

  const medianValueText = summary ? fmtPrecise(currencyCode, summary.median_cents) : "";
  const medianLines = summary ? ["Median", medianValueText] : ["Median"];
  const medianHeight = labelHeight(medianLines.length);
  const medianWidth = approxLabelWidth(medianLines, PAD_X_COMFORTABLE);
  const medianShift = summary ? computeXShift(summary.median_cents, minBin, maxBin, medianWidth / 2) : 0;
  const medianYOffset = medianHeight + LABEL_GAP;
  const topReserve = mode === "real" ? markerLabelHeight + REAL_TOP_BREATHING : PLACEHOLDER_TOP_RESERVE;

  const layout = mode === "real" ? layoutMarkers(priceMarkers, minBin, maxBin) : [];

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
        {/* Dashed-line layer — all lines render before any label */}
        {layout.map((marker) => {
          const fillColor = marker.id === "base" ? BASE_FILL : VARIANT_FILL;
          const yOffset = marker.renderLabel ? marker.stackIndex * (markerLabelHeight + LINE_GAP * 2) : 0;
          const isOffset = marker.renderLabel && yOffset > 0;
          if (isOffset) {
            return (
              <ReferenceLine
                key={`marker-line-${marker.id}`}
                x={marker.valueCents}
                stroke="none"
                ifOverflow="extendDomain"
                isFront
                label={
                  <PartialDashedLine color={fillColor} yOffset={yOffset} labelHeightPx={markerLabelHeight} fromBottom />
                }
              />
            );
          }
          return (
            <ReferenceLine
              key={`marker-line-${marker.id}`}
              x={marker.valueCents}
              stroke={fillColor}
              strokeWidth={2}
              strokeDasharray="4 4"
              ifOverflow="extendDomain"
              isFront
            />
          );
        })}
        {mode === "real" && summary ? (
          <ReferenceLine
            x={summary.median_cents}
            stroke="none"
            ifOverflow="extendDomain"
            isFront
            label={
              <PartialDashedLine color="var(--color-foreground)" yOffset={medianYOffset} labelHeightPx={medianHeight} />
            }
          />
        ) : null}
        {/* Label layer — every label renders after every line */}
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
                padX={PAD_X_COMFORTABLE}
              />
            }
          />
        ) : null}
        {layout
          .filter((marker) => marker.renderLabel)
          .map((marker) => {
            const labelLines = [marker.label];
            const halfWidth = approxLabelWidth(labelLines) / 2;
            const xShift = computeXShift(marker.valueCents, minBin, maxBin, halfWidth);
            const yOffset = marker.stackIndex * (markerLabelHeight + LINE_GAP * 2);
            const fillColor = marker.id === "base" ? BASE_FILL : VARIANT_FILL;
            return (
              <ReferenceLine
                key={`marker-label-${marker.id}`}
                x={marker.valueCents}
                stroke="none"
                ifOverflow="extendDomain"
                isFront
                label={
                  <RefLineLabel
                    title={marker.label}
                    fillColor={fillColor}
                    textColor="var(--color-background)"
                    xShift={xShift}
                    yOffset={yOffset}
                  />
                }
              />
            );
          })}
      </BarChart>
    </ResponsiveContainer>
  );
};
