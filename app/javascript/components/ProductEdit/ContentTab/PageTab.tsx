import { DotsHorizontalRounded, Move, Pencil, Trash } from "@boxicons/react";
import CharacterCount from "@tiptap/extension-character-count";
import Placeholder from "@tiptap/extension-placeholder";
import { EditorContent, useEditor } from "@tiptap/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { PAGE_ICON_COMPONENTS, PAGE_ICON_LABELS, type PageIconType } from "$app/utils/rich_content_page";

import { PageListItem } from "$app/components/Download/PageListLayout";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { BlurOnEnter } from "$app/components/TiptapExtensions/BlurOnEnter";
import PlainTextStarterKit from "$app/components/TiptapExtensions/PlainTextStarterKit";
import { Menu, MenuItem } from "$app/components/ui/Menu";

export type Page = {
  id: string;
  // Client-only until the first successful save. This distinguishes a page
  // that has no source row yet from a stored page whose move must delete its
  // old row.
  newlyAdded?: boolean;
  // Set only while copying a stored page to a new destination. The server uses
  // it to prove that dead foreign embeds in the new page are legacy content,
  // then the post-save reconciliation clears it.
  source_id?: string;
  // Client-only immediate parent for a copy made from another unsaved copy.
  // When that parent save returns, its id mapping rebases source_id to the
  // newly stored row.
  copy_parent_id?: string;
  // Client-only move intent. A scope toggle moves a page by creating a row in
  // the destination and deleting its stored source. Keeping the source scope
  // lets the inverse toggle cancel that intent before save; keeping the source
  // id lets the save contract name exactly the row to delete.
  move_source_scope?: string | null;
  move_source_id?: string;
  // Client-only identity stamped when a save snapshots the page. Ids repeat
  // across scopes and a cancelled move erases move_source_scope, so scope,
  // id, and marker together cannot always tell same-id pages apart once moves
  // land mid-request; this can. Moves spread the page object, so it survives;
  // copies rebuild pages field by field, so a copy correctly starts without
  // one. The server ignores it.
  reconciliation_id?: string;
  title: string | null;
  description: object;
  updated_at: string;
};

export const titleWithFallback = (title: string | null | undefined) => (!title?.trim() ? "Untitled" : title);

export const PageTab = ({
  page,
  selected,
  dragging,
  renaming,
  setRenaming,
  icon,
  onClick,
  onUpdate,
  onDelete,
  disabled,
}: {
  page: Page;
  selected: boolean;
  dragging: boolean;
  icon: PageIconType;
  renaming: boolean;
  setRenaming: (renaming: boolean) => void;
  onClick: () => void;
  onUpdate: (title: string) => void;
  onDelete: () => void;
  disabled?: boolean;
}) => {
  const editor = useEditor({
    extensions: [
      PlainTextStarterKit,
      BlurOnEnter,
      Placeholder.configure({ placeholder: "Name your page" }),
      CharacterCount.configure({ limit: 70 }),
    ],
    editable: true,
    content: page.title,
    onUpdate: ({ editor }) => onUpdate(editor.getText()),
    onBlur: () => setRenaming(false),
  });
  React.useEffect(() => {
    if (renaming) editor?.commands.focus("end");
  }, [renaming, editor]);

  const PageIcon = PAGE_ICON_COMPONENTS[icon];
  return (
    <PageListItem
      onClick={onClick}
      isSelected={selected}
      // .sortable-* are created by react-sortablejs, and we can't add Tailwind classes to them directly.
      className={classNames(
        "group/tab relative [&_.sortable-drag]:border [&_.sortable-drag]:bg-muted [&.sortable-ghost]:outline [&.sortable-ghost]:outline-accent [&.sortable-ghost]:outline-dashed [&.sortable-ghost>_*]:opacity-30",
        { "outline-2 -outline-offset-2 outline-accent": renaming },
      )}
      role="tab"
    >
      {!disabled ? (
        <Move
          className="invisible absolute left-0 size-5 cursor-move text-muted group-hover/tab:visible"
          aria-grabbed={dragging}
        />
      ) : null}
      <PageIcon className="size-5" aria-label={PAGE_ICON_LABELS[icon]} />
      <span className="flex-1">
        {renaming ? <EditorContent editor={editor} className="cursor-text" /> : titleWithFallback(page.title)}
      </span>
      {renaming || disabled ? null : (
        <span onClick={(e) => e.stopPropagation()}>
          <Popover>
            <PopoverTrigger>
              <DotsHorizontalRounded className="size-5" />
            </PopoverTrigger>
            <PopoverContent usePortal className="border-0 p-0 shadow-none">
              <Menu>
                <MenuItem onClick={() => setRenaming(true)}>
                  <Pencil className="size-5" /> Rename
                </MenuItem>
                <MenuItem variant="danger" onClick={onDelete}>
                  <Trash className="size-5" /> Delete
                </MenuItem>
              </Menu>
            </PopoverContent>
          </Popover>
        </span>
      )}
    </PageListItem>
  );
};
