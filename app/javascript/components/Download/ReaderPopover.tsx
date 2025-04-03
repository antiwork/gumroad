import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";

export const ReaderPopover = ({ onZoomIn, onZoomOut }: { onZoomIn: () => void; onZoomOut: () => void }) => (
  <Popover aria-label="Appearance" trigger={<Icon name="zoom-in" />}>
    <fieldset>
      <legend>Appearance</legend>
      <div>
        <Button style={{ marginRight: "var(--spacer-2)" }} onClick={onZoomOut}>
          <Icon name="zoom-out" />
        </Button>
        <Button onClick={onZoomIn}>
          <Icon name="zoom-in" />
        </Button>
      </div>
    </fieldset>
  </Popover>
);
