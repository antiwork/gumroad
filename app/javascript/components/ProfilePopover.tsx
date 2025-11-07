import * as React from "react";

import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";

type BaseUser = { name?: string | null; email?: string | null };
type User = BaseUser & ({ avatarUrl: string; avatar_url?: never } | { avatar_url: string; avatarUrl?: never });

export const DashboardNavProfilePopover = ({ children, user }: { children: React.ReactNode; user: User | null }) => (
  <Popover
    position="top"
    trigger={(open: boolean) => (
      <div className="inline-flex px-6 py-4 hover:text-accent">
        <div className="flex-1">
          <img
            className="user-avatar mr-3 border border-white! dark:border-foreground/35!"
            src={user?.avatarUrl || user?.avatar_url}
            alt="Your avatar"
          />
          {user?.name || user?.email}
        </div>
        <Icon name={open ? "outline-cheveron-up" : "outline-cheveron-down"} />
      </div>
    )}
    className="border-y border-white/50 border-b-transparent after:border-t-white! dark:border-foreground/50 dark:border-b-transparent dark:after:border-t-foreground/35!"
    dropdownClassName="mx-4 border-white/35! dark:border-foreground/35!"
  >
    {children}
  </Popover>
);
