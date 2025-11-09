import * as React from "react";

import { Tab, TabIcon, Tabs as TabsComponent } from "$app/components/ui/Tabs";

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
}) => (
  <TabsComponent variant="buttons">
    <Tab onClick={() => setTab("overlay")} isSelected={tab === "overlay"} aria-controls={overlayTabpanelUID}>
      <TabIcon name="stickies" />
      <div>
        <h4 className="font-bold">Modal Overlay</h4>
        <small className="text-sm">Pop up product information with a familiar and trusted buying experience.</small>
      </div>
    </Tab>
    <Tab onClick={() => setTab("embed")} isSelected={tab === "embed"} aria-controls={embedTabpanelUID}>
      <TabIcon name="code-square" />
      <div>
        <h4 className="font-bold">Embed</h4>
        <small className="text-sm">Embed on your website, blog posts & more.</small>
      </div>
    </Tab>
  </TabsComponent>
);
