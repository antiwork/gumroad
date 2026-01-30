import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";

type Props = { contentHTML: string };

export const FilterPopover = ({ contentHTML }: Props) => (
  <Popover>
    <PopoverTrigger aria-label="Filter" className="js-toggle-filter-list" asChild>
      <Button>
        <Icon name="filter" />
      </Button>
    </PopoverTrigger>
    <PopoverContent sideOffset={4}>
      <div
        className="js-filter-list customer-popover--filter filter-box"
        dangerouslySetInnerHTML={{ __html: contentHTML }}
        suppressHydrationWarning
        style={{ margin: "calc(-1 * var(--spacer-4) - var(--border-width))", maxWidth: "unset" }}
      />
    </PopoverContent>
  </Popover>
);

export default register({ component: FilterPopover, propParser: createCast() });
