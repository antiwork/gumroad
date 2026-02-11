import * as PopoverPrimitive from "@radix-ui/react-popover";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const Popover = PopoverPrimitive.Root;
export const PopoverClose = PopoverPrimitive.Close;

export const PopoverAnchor = React.forwardRef<
  React.ElementRef<typeof PopoverPrimitive.Anchor>,
  React.ComponentPropsWithoutRef<typeof PopoverPrimitive.Anchor>
>(({ className, ...props }, ref) => (
  // Grid layout ensures children match the parent width by default
  <PopoverPrimitive.Anchor ref={ref} className={classNames("grid", className)} {...props} />
));
PopoverAnchor.displayName = PopoverPrimitive.Anchor.displayName;

export const PopoverTrigger = React.forwardRef<
  React.ElementRef<typeof PopoverPrimitive.Trigger>,
  React.ComponentPropsWithoutRef<typeof PopoverPrimitive.Trigger>
>(({ className, ...props }, ref) => (
  <PopoverPrimitive.Trigger
    ref={ref}
    className={classNames("cursor-pointer outline-none all-unset focus-visible:outline-none", className)}
    {...props}
  />
));
PopoverTrigger.displayName = PopoverPrimitive.Trigger.displayName;

export const PopoverContent = React.forwardRef<
  React.ElementRef<typeof PopoverPrimitive.Content>,
  React.ComponentPropsWithoutRef<typeof PopoverPrimitive.Content> & {
    matchTriggerWidth?: boolean;
    arrowClassName?: string;
    usePortal?: boolean;
  }
>(
  (
    {
      children,
      className,
      arrowClassName,
      align = "start",
      collisionPadding = 16,
      matchTriggerWidth = false,
      usePortal = false,
      ...props
    },
    ref,
  ) => {
    const content = (
      <PopoverPrimitive.Content
        ref={ref}
        align={align}
        collisionPadding={collisionPadding}
        autoFocus={false}
        forceMount
        onOpenAutoFocus={(e: Event) => e.preventDefault()}
        className={classNames(
          "z-30 w-max max-w-[calc(100vw-2rem)] rounded-sm border border-border bg-background p-4 text-foreground shadow outline-none focus-visible:outline-none data-[state=closed]:hidden",
          { "w-[var(--radix-popover-trigger-width)] min-w-[var(--radix-popover-trigger-width)]": matchTriggerWidth },
          className,
        )}
        {...props}
      >
        {children}
        <PopoverPrimitive.Arrow
          width={16}
          height={8}
          className={classNames("fill-black data-[state=closed]:hidden dark:fill-foreground/35", arrowClassName)}
        />
      </PopoverPrimitive.Content>
    );

    return usePortal ? <PopoverPrimitive.Portal forceMount>{content}</PopoverPrimitive.Portal> : content;
  },
);
PopoverContent.displayName = PopoverPrimitive.Content.displayName;
