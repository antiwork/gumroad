import { ArrowDown, ArrowUp, ChevronLeft, DotsVerticalRounded, Trash } from "@boxicons/react";
import { Slot } from "@radix-ui/react-slot";
import { Editor } from "@tiptap/core";
import * as React from "react";

import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";

import { Button } from "$app/components/Button";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";

const SelectedContext = React.createContext(false);

export const NodeActionsWrapper = ({
  selected = false,
  isEditable = true,
  asChild,
  className,
  children,
  ...rest
}: {
  selected?: boolean;
  isEditable?: boolean;
  asChild?: boolean;
} & React.HTMLAttributes<HTMLDivElement>) => {
  const Component = asChild ? Slot : "div";
  return (
    <SelectedContext.Provider value={selected}>
      <Component
        className={classNames(
          isEditable && [
            "relative before:absolute before:[inset:0_100%_0_-3rem] before:content-['']",
            "[&:hover>[data-actions-menu]]:lg:block",
            "[&:has([data-child-area]:hover)>[data-actions-menu]]:lg:hidden",
          ],
          selected && "relative rounded outline-2 outline-accent [&_*::selection]:bg-transparent",
          className,
        )}
        {...rest}
      >
        {children}
      </Component>
    </SelectedContext.Provider>
  );
};

export const NodeActionsMenu = ({
  editor,
  actions,
}: {
  editor: Editor;
  actions?: { item: () => React.ReactNode; menu: (close: () => void) => React.ReactNode }[];
}) => {
  const [open, setOpen] = React.useState(false);
  const [selectedActionIndex, setSelectedActionIndex] = React.useState<number | null>(null);
  const selected = React.useContext(SelectedContext);

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <div
        data-actions-menu
        className={classNames(
          "absolute bottom-4 left-0 z-1 text-base lg:top-6 lg:bottom-auto lg:-left-2 lg:-translate-x-full",
          !selected && !open && "lg:hidden",
        )}
      >
        <PopoverAnchor>
          <PopoverTrigger aria-label="Actions" data-drag-handle draggable asChild>
            <Button size="sm" color="filled">
              <DotsVerticalRounded pack="filled" className="size-5" />
            </Button>
          </PopoverTrigger>
        </PopoverAnchor>
        <PopoverContent usePortal sideOffset={4} className="border-0 p-0 shadow-none">
          <div role="menu">
            {actions && selectedActionIndex !== null ? (
              <>
                <div onClick={() => setSelectedActionIndex(null)} role="menuitem">
                  <ChevronLeft className="size-5" />
                  <span>Back</span>
                </div>
                {assertDefined(actions[selectedActionIndex]).menu(() => setOpen(false))}
              </>
            ) : (
              <>
                <div onClick={() => editor.commands.moveNodeUp()} role="menuitem">
                  <ArrowUp className="size-5" />
                  <span>Move up</span>
                </div>
                <div onClick={() => editor.commands.moveNodeDown()} role="menuitem">
                  <ArrowDown className="size-5" />
                  <span>Move down</span>
                </div>
                {actions?.map(({ item }, index) => (
                  <div key={index} onClick={() => setSelectedActionIndex(index)} role="menuitem">
                    {item()}
                  </div>
                ))}
                <div
                  style={{ color: "rgb(var(--danger))" }}
                  onClick={() => editor.commands.deleteSelection()}
                  role="menuitem"
                >
                  <Trash className="size-5" />
                  <span>Delete</span>
                </div>
              </>
            )}
          </div>
        </PopoverContent>
      </div>
    </Popover>
  );
};
