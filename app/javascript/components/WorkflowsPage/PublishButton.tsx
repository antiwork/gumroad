import * as React from "react";

import { type SaveActionName } from "$app/types/workflow";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";
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
}: PublishButtonProps) =>
  isPublished ? (
    <Button onClick={() => onClick("save_and_unpublish")} disabled={isDisabled}>
      Unpublish
    </Button>
  ) : wasPublishedPreviously || sendToPastCustomers === null ? (
    <Button color="accent" onClick={() => onClick("save_and_publish")} disabled={isDisabled}>
      Publish
    </Button>
  ) : (
    <Popover>
      <PopoverAnchor>
        <PopoverTrigger disabled={isDisabled} asChild>
          <Button color="accent">
            Publish
            <Icon name="outline-cheveron-down" />
          </Button>
        </PopoverTrigger>
      </PopoverAnchor>
      <PopoverContent sideOffset={4}>
        <fieldset>
          <Button color="accent" onClick={() => onClick("save_and_publish")} disabled={isDisabled}>
            Publish now
          </Button>
          <Toggle value={sendToPastCustomers.enabled} onChange={sendToPastCustomers.toggle}>
            {sendToPastCustomers.label}
          </Toggle>
        </fieldset>
      </PopoverContent>
    </Popover>
  );
