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

export type Page = {
  id: string;
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
        <Move className="invisible absolute left-0 size-5 text-muted group-hover/tab:visible" aria-grabbed={dragging} />
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
              <div role="menu">
                <div role="menuitem" onClick={() => setRenaming(true)}>
                  <Pencil className="size-5" /> Rename
                </div>
                <div className="danger" role="menuitem" onClick={onDelete}>
                  <Trash className="size-5" /> Delete
                </div>
              </div>
            </PopoverContent>
          </Popover>
        </span>
      )}
    </PageListItem>
  );
};
