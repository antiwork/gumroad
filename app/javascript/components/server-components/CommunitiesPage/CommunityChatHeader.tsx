import cx from "classnames";
import * as React from "react";

import { Community } from "$app/data/communities";

import { Icon } from "$app/components/Icons";

export const CommunityChatHeader = ({
  community,
  setSidebarOpen,
  isAboveBreakpoint,
}: {
  community: Community;
  setSidebarOpen: (open: boolean) => void;
  isAboveBreakpoint: boolean;
}) => (
  <div className="m-0 flex justify-between gap-2 border-b px-6">
    <button
      className={cx("flex-shrink-0", { hidden: isAboveBreakpoint })}
      aria-label="Open sidebar"
      onClick={() => setSidebarOpen(true)}
    >
      <Icon name="outline-menu" className="text-sm" />
    </button>
    <h1 className="flex-1 truncate py-3 text-base font-bold">{community.name}</h1>
  </div>
);
