import * as React from "react";

import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";

export const LocationsPopover = ({
  selected,
  setSelected,
}: {
  selected: string;
  setSelected: (value: string) => void;
}) => (
  <Popover
    trigger={
      <div className="input" aria-label="Locations selector">
        <span>{selected === "world" ? "World" : "United States"}</span>
        <Icon name="outline-cheveron-down" className="ml-auto" />
      </div>
    }
  >
    {(close) => (
      <div role="menu" className="text-base">
        <div
          role="menuitem"
          onClick={() => {
            setSelected("world");
            close();
          }}
        >
          World
        </div>
        <div
          role="menuitem"
          onClick={() => {
            setSelected("us");
            close();
          }}
        >
          United States
        </div>
      </div>
    )}
  </Popover>
);
