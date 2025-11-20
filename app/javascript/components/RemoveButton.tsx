import * as React from "react";

// This component requires a `position: relative;` somewhere up
// the chain for correct top/right positioning.
export const RemoveButton = ({ style, ...props }: React.HTMLAttributes<HTMLDivElement>) => (
  <div {...props} style={{ ...style, width: "var(--big-icon-size)", display: "inline-block", cursor: "pointer" }}>
    <svg viewBox="0 0 1 1" style={{ width: "100%", height: "100%" }}>
      <circle cx="0.5" cy="0.5" r="0.375" style={{ fill: "rgb(var(--danger))" }} />
      <path
        d="M0.39 0.39L0.61 0.61M0.61 0.39L0.39 0.61"
        style={{ stroke: "rgb(var(--filled))", strokeWidth: "0.11px", strokeLinecap: "round" }}
      />
    </svg>
  </div>
);
