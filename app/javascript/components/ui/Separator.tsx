import React from "react";

export const Separator = ({
  text,
  children,
  className = "",
}: {
  text?: string;
  children?: React.ReactNode;
  className?: string;
}) => (
  <div role="separator" className={`flex items-center gap-3 ${className}`.trim()}>
    <div className="flex-1 h-px border-b border-solid border-[rgb(var(--parent-color)/var(--border-alpha))]"></div>
    {children || <span>{text || "or"}</span>}
    <div className="flex-1 h-px border-b border-solid border-[rgb(var(--parent-color)/var(--border-alpha))]"></div>
  </div>
);
