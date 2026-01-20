import * as React from "react";
import { createCast } from "ts-safe-cast";

import { classNames } from "$app/utils/classNames";
import { register } from "$app/utils/serverComponentUtil";

import { buttonVariants } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { WithTooltip } from "$app/components/WithTooltip";

type Props = { contentHTML: string };

export const FilterPopover = ({ contentHTML }: Props) => (
  <Popover
    aria-label="Filter"
    trigger={
      <WithTooltip tip="Filter" position="bottom">
        <div className={classNames(buttonVariants({ size: "default" }), "js-toggle-filter-list")}>
          <Icon name="filter" />
        </div>
      </WithTooltip>
    }
  >
    <div
      className="js-filter-list customer-popover--filter filter-box"
      dangerouslySetInnerHTML={{ __html: contentHTML }}
      suppressHydrationWarning
      style={{ margin: "calc(-1 * var(--spacer-4) - var(--border-width))", maxWidth: "unset" }}
    />
  </Popover>
);

export default register({ component: FilterPopover, propParser: createCast() });
