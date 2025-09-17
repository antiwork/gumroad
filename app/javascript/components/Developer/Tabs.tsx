import cx from "classnames";
import * as React from "react";

import { Button } from "../Button";
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
  const selectTab = (evt: React.MouseEvent<HTMLButtonElement>, tab: Tab) => {
    evt.preventDefault();
    setTab(tab);
  };

  return (
    <div className="tab-buttons" role="tablist">
      <Button
        onClick={(evt) => selectTab(evt, "overlay")}
        className={cx(tab === "overlay" ? "selected" : null)}
        role="tab"
        aria-selected={tab === "overlay"}
        aria-controls={overlayTabpanelUID}
      >
        <Icon name="stickies" />
        <div>
          <h4 className="tab-title">Modal Overlay</h4>
          <small>Pop up product information with a familiar and trusted buying experience.</small>
        </div>
      </Button>
      <Button
        onClick={(evt) => selectTab(evt, "embed")}
        className={cx(tab === "embed" ? "selected" : null)}
        role="tab"
        aria-selected={tab === "embed"}
        aria-controls={embedTabpanelUID}
      >
        <Icon name="code-square" />
        <div>
          <h4 className="tab-title">Embed</h4>
          <small>Embed on your website, blog posts & more.</small>
        </div>
      </Button>
    </div>
  );
};
