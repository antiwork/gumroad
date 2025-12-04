import * as React from "react";

import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";

export const AggregateByPopover = ({
  aggregateBy,
  setAggregateBy,
}: {
  aggregateBy: "daily" | "monthly";
  setAggregateBy: (value: "daily" | "monthly") => void;
}) => (
  <Popover
    trigger={
      <div className="input" aria-label="Aggregate by selector">
        <span>{aggregateBy === "daily" ? "Daily" : "Monthly"}</span>
        <Icon name="outline-cheveron-down" className="ml-auto" />
      </div>
    }
  >
    {(close) => (
      <div role="menu">
        <div
          role="menuitem"
          onClick={() => {
            setAggregateBy("daily");
            close();
          }}
        >
          Daily
        </div>
        <div
          role="menuitem"
          onClick={() => {
            setAggregateBy("monthly");
            close();
          }}
        >
          Monthly
        </div>
      </div>
    )}
  </Popover>
);
