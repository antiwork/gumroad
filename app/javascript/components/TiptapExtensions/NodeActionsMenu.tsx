import { Editor } from "@tiptap/core";
import { NodeSelection } from "@tiptap/pm/state";
import * as React from "react";

import { assertDefined } from "$app/utils/assert";

import { buttonVariants } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";

export const NodeActionsMenu = ({
  editor,
  actions,
}: {
  editor: Editor;
  actions?: { item: () => React.ReactNode; menu: (close: () => void) => React.ReactNode }[];
}) => {
  const [open, setOpen] = React.useState(false);
  const selectedNode = editor.state.selection instanceof NodeSelection ? editor.state.selection.node : null;
  const [selectedActionIndex, setSelectedActionIndex] = React.useState<number | null>(null);

  React.useEffect(() => {
    if (selectedNode === null) setOpen(false);
  }, [selectedNode]);

  return (
    <Popover
      open={open}
      onToggle={setOpen}
      className="actions-menu"
      aria-label="Actions"
      trigger={
        <div className={buttonVariants({ size: "sm", color: "filled" })} data-drag-handle draggable>
          <Icon name="outline-drag" />
        </div>
      }
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
    </Popover>
  );
};
