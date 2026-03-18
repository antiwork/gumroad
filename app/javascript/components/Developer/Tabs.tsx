import { CodeAlt, NoteBook } from "@boxicons/react";
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
      <TabIcon>
        <NoteBook className="size-5" />
      </TabIcon>
      <div>
        <h4 className="font-bold">Modal Overlay</h4>
        <small className="block text-sm">
          Pop up product information with a familiar and trusted buying experience.
        </small>
      </div>
    </Tab>
    <Tab onClick={() => setTab("embed")} isSelected={tab === "embed"} aria-controls={embedTabpanelUID}>
      <TabIcon>
        <CodeAlt className="size-5" />
      </TabIcon>
      <div>
        <h4 className="font-bold">Embed</h4>
        <small className="block text-sm">Embed on your website, blog posts & more.</small>
      </div>
    </Tab>
  </TabsComponent>
);
