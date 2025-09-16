import * as React from "react";

import { Tabs as UITabs, Tab } from "$app/components/ui/Tabs";

import { Icon } from "../Icons";

export type Tab = "overlay" | "embed";

export const Tabs = ({
  tab,
  setTab,
  overlayTabpanelUID,
  embedTabpanelUID,
}: {
  tab: Tab;
  setTab: React.Dispatch<React.SetStateAction<Tab>>;
  overlayTabpanelUID?: string;
  embedTabpanelUID?: string;
}) => {
  const selectTab = (evt: React.MouseEvent<HTMLAnchorElement>, tab: Tab) => {
    evt.preventDefault();
    setTab(tab);
  };

  return (
    <UITabs>
      <Tab
        onClick={(evt) => selectTab(evt, "overlay")}
        isSelected={tab === "overlay"}
        aria-controls={overlayTabpanelUID}
      >
        <Icon name="stickies" />
        <div>
          <h4 className="tab-title">Modal Overlay</h4>
          <small>Pop up product information with a familiar and trusted buying experience.</small>
        </div>
      </Tab>
      <Tab onClick={(evt) => selectTab(evt, "embed")} isSelected={tab === "embed"} aria-controls={embedTabpanelUID}>
        <Icon name="code-square" />
        <div>
          <h4 className="tab-title">Embed</h4>
          <small>Embed on your website, blog posts & more.</small>
        </div>
      </Tab>
    </UITabs>
  );
};
