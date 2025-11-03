import React from "react";

const TabList = ({ children }: { children: React.ReactNode }) => (
  <div role="tablist" className="grid auto-cols-[1fr] grid-flow-col gap-3">
    {children}
  </div>
);

export default TabList;
