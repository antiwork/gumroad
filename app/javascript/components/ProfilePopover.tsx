import * as React from "react";

import { Icon } from "$app/components/Icons";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";

type User = { name: string | null; email: string | null; avatarUrl: string };

export const DashboardNavProfilePopover = ({ children, user }: { children: React.ReactNode; user: User | null }) => (
  <Popover>
    <PopoverTrigger className="group flex items-center justify-between overflow-hidden border-t border-white/50 px-6 py-4 all-unset hover:text-accent dark:border-foreground/50">
      <div className="flex-1 truncate">
        <img
          className="user-avatar mr-3 border border-white! dark:border-foreground/35!"
          src={user?.avatarUrl}
          alt="Your avatar"
        />
        {user?.name || user?.email}
      </div>
      <Icon name="outline-cheveron-down" className="group-data-[state=open]:rotate-180" />
    </PopoverTrigger>
    <PopoverContent
      side="top"
      className="border-0 p-0 shadow-none"
      arrowClassName="fill-white"
      collisionPadding={0}
      matchTriggerWidth
    >
      {children}
    </PopoverContent>
  </Popover>
);
