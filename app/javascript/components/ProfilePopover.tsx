import { ChevronDown } from "@boxicons/react";
import * as React from "react";

import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Avatar } from "$app/components/ui/Avatar";

type User = { name: string | null; email: string | null; avatarUrl: string };

export const DashboardNavProfilePopover = ({ children, user }: { children: React.ReactNode; user: User | null }) => (
  <Popover>
    <PopoverTrigger className="group flex items-center justify-between overflow-hidden border-t border-white/50 px-6 py-4 all-unset hover:text-accent dark:border-foreground/50">
      <div className="flex-1 truncate">
        <Avatar className="mr-3 border-white! dark:border-foreground/35!" src={user?.avatarUrl} alt="Your avatar" />
        {user?.name || user?.email}
      </div>
      <ChevronDown className="size-5 group-data-[state=open]:rotate-180" />
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
