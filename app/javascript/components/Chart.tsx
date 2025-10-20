import * as React from "react";
import { ResponsiveContainer, ComposedChart, XAxisProps, YAxisProps, LineProps } from "recharts";

type TickProps = {
  x: number;
  y: number;
  payload: { value: string; index: number };
};

type DotProps = {
  key: string;
  cx: number;
  cy: number;
  width: number;
};

export const Chart = ({
  aspect,
  containerRef,
  tooltipPosition,
  tooltip,
  ...props
}: {
  aspect?: number;
  containerRef: React.RefObject<HTMLDivElement>;
  tooltipPosition: { left: number; top: number } | null;
  tooltip: React.ReactNode;
} & React.ComponentPropsWithoutRef<typeof ComposedChart>) => {
  const uid = React.useId();
  return (
    <section
      className="rounded border border-border bg-background p-6 text-foreground"
      data-testid="chart"
      aria-describedby={tooltip ? uid : undefined}
    >
      <div className="relative">
        <ResponsiveContainer aspect={aspect ?? 1092 / 450} maxHeight={650} ref={containerRef}>
          <ComposedChart margin={{ top: 32, right: 0, bottom: 16, left: 0 }} {...props} />
        </ResponsiveContainer>
        {tooltipPosition && tooltip ? (
          <div className="has-tooltip top" style={{ position: "absolute", ...tooltipPosition }}>
            <div
              id={uid}
              role="tooltip"
              style={{
                display: "block",
                width: "max-content",
                pointerEvents: "none",
              }}
            >
              {tooltip}
            </div>
          </div>
        ) : null}
      </div>
    </section>
  );
};

export const xAxisProps: XAxisProps = {
  tick: ({ x, y, payload }: TickProps) => (
    <text x={x} y={y} dy={16} textAnchor={payload.index > 0 ? "end" : "start"} fill="currentColor">
      {payload.value}
    </text>
  ),
  interval: "preserveStartEnd",
  tickLine: false,
  axisLine: { stroke: "currentColor" },
};

export const yAxisProps: YAxisProps = {
  tick: { fill: "currentColor" },
  tickCount: 3,
  tickLine: false,
  axisLine: { stroke: "currentColor" },
};

export const lineProps = (
  dotRef: (element: SVGCircleElement) => void,
  dotCount: number,
): React.PropsWithoutRef<LineProps> => ({
  stroke: "rgb(var(--accent))",
  strokeWidth: 2,
  isAnimationActive: false,
  dot: ({ key, cx, cy, width }: DotProps) => (
    <circle
      ref={dotRef}
      key={key}
      cx={cx}
      cy={cy}
      r={Math.min(width / dotCount / 7, 8)}
      fill="rgb(var(--accent))"
      stroke="none"
      data-testid="chart-dot"
    />
  ),
});
