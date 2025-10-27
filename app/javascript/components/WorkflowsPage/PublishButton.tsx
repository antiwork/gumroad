import * as React from "react";

import { type SaveActionName } from "$app/types/workflow";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { Toggle } from "$app/components/Toggle";

type PublishButtonProps = {
  isPublished: boolean;
  wasPublishedPreviously: boolean;
  isDisabled: boolean;
  sendToPastCustomers: {
    enabled: boolean;
    toggle: (value: boolean) => void;
    label: string;
  } | null;
  onClick: (saveActionName: SaveActionName) => void;
};

export const PublishButton = ({
  isPublished,
  wasPublishedPreviously,
  isDisabled,
  sendToPastCustomers,
  onClick,
}: PublishButtonProps) => {
  const [popoverOpen, setPopoverOpen] = React.useState(false);

  return isPublished ? (
    <Button onClick={() => onClick("save_and_unpublish")} disabled={isDisabled}>
      Unpublish
    </Button>
  ) : wasPublishedPreviously || sendToPastCustomers === null ? (
    <Button color="accent" onClick={() => onClick("save_and_publish")} disabled={isDisabled}>
      Publish
    </Button>
  ) : (
    <Popover
      disabled={isDisabled}
      trigger={
        <div className="button" color="accent">
          Publish
          <Icon name="outline-cheveron-down" />
        </div>
      }
      open={popoverOpen}
      onToggle={setPopoverOpen}
    >
      <fieldset>
        <Button color="accent" onClick={() => onClick("save_and_publish")} disabled={isDisabled}>
          Publish now
        </Button>
        <Toggle value={sendToPastCustomers.enabled} onChange={sendToPastCustomers.toggle}>
          {sendToPastCustomers.label}
        </Toggle>
      </fieldset>
    </Popover>
  );
};
