import { ChevronDown } from "@boxicons/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Avatar } from "$app/components/ui/Avatar";

type User = { name: string | null; email: string | null; avatarUrl: string };

/** "sidebar" opens upward from the foot of the sidebar; "header" opens downward from the header's right end. */
export const DashboardNavProfilePopover = ({
  children,
  user,
  placement = "sidebar",
}: {
  children: React.ReactNode;
  user: User | null;
  placement?: "sidebar" | "header";
}) => {
  // The nav outlives a visit, so the menu closes itself once a row is chosen. Not for an account
  // row: switching reloads the page, and until then the menu stays to show what was chosen.
  const [open, setOpen] = React.useState(false);
  const closeOnChoice = (event: React.MouseEvent) => {
    if (event.target instanceof Element && event.target.closest("[role=menuitemradio]")) return;
    setOpen(false);
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger
        // The header shows the name only where there is room, so the trigger is named here.
        {...(placement === "header" && { "aria-label": `${user?.name || user?.email || "Your"} account` })}
        className={classNames(
          "group flex items-center justify-between overflow-hidden all-unset hover:text-accent",
          placement === "sidebar"
            ? "border-t border-white/50 px-6 py-4 dark:border-foreground/50"
            : // outline-solid replaces the trigger's own outline-none, which would otherwise hide the ring.
              "max-w-56 shrink-0 gap-2 rounded px-2 py-1 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-current focus-visible:outline-solid",
        )}
      >
        <div className="flex-1 truncate">
          <Avatar
            className={classNames(
              "border-white! dark:border-foreground/35!",
              placement === "sidebar" ? "mr-3" : "min-[1800px]:mr-3",
            )}
            src={user?.avatarUrl}
            alt={placement === "sidebar" ? "Your avatar" : ""}
          />
          <span className={placement === "header" ? "hidden min-[1800px]:inline" : undefined}>
            {user?.name || user?.email}
          </span>
        </div>
        <ChevronDown className="size-5 shrink-0 group-data-[state=open]:rotate-180" />
      </PopoverTrigger>
      {placement === "sidebar" ? (
        <PopoverContent
          side="top"
          className="border-0 px-2 py-1 shadow-none"
          arrowClassName="fill-white"
          collisionPadding={0}
          matchTriggerWidth
          onClick={closeOnChoice}
        >
          {children}
        </PopoverContent>
      ) : (
        <PopoverContent side="bottom" align="end" className="min-w-56 px-2 py-1" onClick={closeOnChoice}>
          {children}
        </PopoverContent>
      )}
    </Popover>
  );
};
