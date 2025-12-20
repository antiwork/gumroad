import * as React from "react";

export const Ribbon = ({ children }: { children: React.ReactNode }) => (
  <div
    className="absolute top-0 left-[-1.464rem] w-20 origin-bottom-right -translate-y-full -rotate-45 border border-border bg-accent text-center text-sm"
    style={{
      clipPath:
        "polygon(calc(1lh + 2 * var(--border-width)) 0, calc(100% - (1lh + 2 * var(--border-width))) 0, 100% 100%, 0 100%)",
    }}
  >
    {children}
  </div>
);
