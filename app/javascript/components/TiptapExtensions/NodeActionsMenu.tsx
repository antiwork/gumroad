import { Editor } from "@tiptap/core";
import * as React from "react";

import { assertDefined } from "$app/utils/assert";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";

export const NodeActionsMenu = ({
  editor,
  actions,
}: {
  editor: Editor;
  actions?: { item: () => React.ReactNode; menu: (close: () => void) => React.ReactNode }[];
}) => {
  const [open, setOpen] = React.useState(false);
  const [selectedActionIndex, setSelectedActionIndex] = React.useState<number | null>(null);

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <div className="actions-menu">
        <PopoverAnchor>
          <PopoverTrigger aria-label="Actions" data-drag-handle draggable asChild>
            <Button small color="filled">
              <Icon name="outline-drag" />
            </Button>
          </PopoverTrigger>
        </PopoverAnchor>
        <PopoverContent
          sideOffset={4}
          className="border-0 p-0 shadow-none"
          onInteractOutside={(e) => e.preventDefault()}
        >
          <div role="menu">
            {actions && selectedActionIndex !== null ? (
              <>
                <div onClick={() => setSelectedActionIndex(null)} role="menuitem">
                  <Icon name="outline-cheveron-left" />
                  <span>Back</span>
                </div>
                {assertDefined(actions[selectedActionIndex]).menu(() => setOpen(false))}
              </>
            ) : (
              <>
                <div onClick={() => editor.commands.moveNodeUp()} role="menuitem">
                  <Icon name="arrow-up" />
                  <span>Move up</span>
                </div>
                <div onClick={() => editor.commands.moveNodeDown()} role="menuitem">
                  <Icon name="arrow-down" />
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
                  <Icon name="trash2" />
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
