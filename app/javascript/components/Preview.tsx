import * as React from "react";

import { useElementDimensions } from "$app/components/useElementDimensions";

export const Preview = ({
  scaleFactor,
  children,
  style,
}: {
  scaleFactor: number;
  children: React.ReactNode;
  style?: React.CSSProperties;
}) => {
  const ref = React.useRef<HTMLDivElement>(null);
  const height = useElementDimensions(ref)?.height;
  return (
    <div role="document" style={{ height: Math.ceil(height ?? 0), overflow: "hidden" }}>
      <div
        ref={ref}
        style={{
          pointerEvents: "none",
          transform: `scale(${scaleFactor})`,
          transformOrigin: "top left",
          width: `${100 / scaleFactor}%`,
          maxWidth: "unset",
          ...style,
        }}
      >
        {children}
      </div>
    </div>
  );
};
