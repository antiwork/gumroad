import * as React from "react";

import { TabButton, TabButtonIcon, TabButtons } from "$app/components/ui/TabButtons";

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
  <TabButtons>
    <TabButton onClick={() => setTab("overlay")} isSelected={tab === "overlay"} aria-controls={overlayTabpanelUID}>
      <TabButtonIcon name="stickies" />
      <div>
        {" "}
        <h4 className="font-bold">Modal Overlay</h4>
        <small className="text-sm">Pop up product information with a familiar and trusted buying experience.</small>
      </div>
    </TabButton>
    <TabButton onClick={() => setTab("embed")} isSelected={tab === "embed"} aria-controls={embedTabpanelUID}>
      <TabButtonIcon name="code-square" />
      <div>
        {" "}
        <h4 className="font-bold">Embed</h4>
        <small className="text-sm">Embed on your website, blog posts & more.</small>
      </div>
    </TabButton>
  </TabButtons>
);
