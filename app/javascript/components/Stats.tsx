import { cva } from "class-variance-authority";
import * as React from "react";

import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";
import { WithTooltip } from "$app/components/WithTooltip";

const statsVariants = cva(
  "text-4xl leading-tight p-8 border border-border rounded grid content-between gap-2 bg-background",
  {
    variants: {
      variant: {
        success: "text-green",
        danger: "text-red",
        warning: "text-orange",
        info: "text-purple",
      },
    },
  },
);

export const Stats = ({
  title,
  description,
  value,
  variant,
  className,
}: {
  title: React.ReactNode;
  description?: string;
  value?: string;
  className?: string;
  variant?: "success" | "danger" | "warning" | "info";
}) => {
  const [adjustedFontSize, setAdjustedFontSize] = React.useState<number | null>(null);
  const containerRef = React.useRef<HTMLDivElement | null>(null);

  React.useEffect(() => {
    const calculateFontSize = () => {
      if (!containerRef.current) return;
      const style = window.getComputedStyle(containerRef.current);
      const containerWidth = containerRef.current.getBoundingClientRect().width;
      document.fonts.ready
        .then(() => {
          const canvas = document.createElement("canvas");
          const context = assertDefined(canvas.getContext("2d"), "Canvas 2d context missing");
          context.font = `${style.fontSize} ${style.fontFamily}`;
          const valueWidth = context.measureText(value ?? "").width;
          const fontSize = parseFloat(style.fontSize);
          setAdjustedFontSize(valueWidth > containerWidth ? (containerWidth * fontSize) / valueWidth : fontSize);
        })
        .catch(() => setAdjustedFontSize(parseFloat(style.fontSize)));
    };
    calculateFontSize();
    window.addEventListener("resize", calculateFontSize);
    return () => window.removeEventListener("resize", calculateFontSize);
  }, [value]);

  return (
    <section className={classNames(statsVariants({ variant }), className)}>
      <h2 className="flex gap-2 text-base">
        {title}
        {description ? (
          <WithTooltip tip={description} position="top">
            <Icon name="info-circle" />
          </WithTooltip>
        ) : null}
      </h2>
      <div ref={containerRef} className="overflow-hidden break-words">
        <span style={adjustedFontSize ? { fontSize: adjustedFontSize } : undefined}>{value ?? "-"}</span>
      </div>
    </section>
  );
};
