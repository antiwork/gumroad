import cx from "classnames";
import * as React from "react";

import { assertDefined } from "$app/utils/assert";

import { Icon } from "$app/components/Icons";
import { WithTooltip } from "$app/components/WithTooltip";

export const Stats = ({
  title,
  description,
  value,
  className,
}: {
  title: React.ReactNode;
  description?: string;
  value?: string;
  className?: string;
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
    <section className={cx("stats", className)}>
      <h2>
        {title}
        {description ? (
          <WithTooltip tip={description} position="top">
            <Icon name="info-circle" />
          </WithTooltip>
        ) : null}
      </h2>
      <div ref={containerRef} style={{ overflow: "hidden", overflowWrap: "initial" }}>
        <span style={adjustedFontSize ? { fontSize: adjustedFontSize } : undefined}>{value ?? "-"}</span>
      </div>
    </section>
  );
};
