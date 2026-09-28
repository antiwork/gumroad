import * as React from "react";

// Each 45deg end cut is as deep as the band is tall, so padding by that depth keeps any label clear of it. Shifting
// left by (1 - 1/√2) of the band's own width lands both cut ends on the card edges whatever width the label needs.
const CUT_DEPTH = "calc(1lh + 2 * var(--border-width))";

export const Ribbon = ({ children }: { children: React.ReactNode }) => (
  <div
    className="absolute top-0 left-0 w-max min-w-20 origin-bottom-right -translate-x-[29.289%] -translate-y-full -rotate-45 border border-border bg-accent-with-text text-center text-sm whitespace-nowrap text-accent-foreground"
    style={{
      clipPath: `polygon(${CUT_DEPTH} 0, calc(100% - ${CUT_DEPTH}) 0, 100% 100%, 0 100%)`,
      paddingInline: CUT_DEPTH,
    }}
  >
    {children}
  </div>
);
