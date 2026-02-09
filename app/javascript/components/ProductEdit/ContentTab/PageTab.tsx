import CharacterCount from "@tiptap/extension-character-count";
import Placeholder from "@tiptap/extension-placeholder";
import { EditorContent, useEditor } from "@tiptap/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { generatePageIcon } from "$app/utils/rich_content_page";

import { PageListItem } from "$app/components/Download/PageListLayout";
import { Icon } from "$app/components/Icons";
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
  icon: ReturnType<typeof generatePageIcon>;
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

  const iconLabels = {
    "file-arrow-down": "Page has various types of files",
    "file-music": "Page has audio files",
    "file-play": "Page has videos",
    "file-text": "Page has no files",
    "outline-key": "Page has license key",
  };
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
        <Icon
          name="outline-drag"
          className="invisible absolute left-0 text-muted group-hover/tab:visible"
          aria-grabbed={dragging}
        />
      ) : null}
      <Icon name={icon} aria-label={iconLabels[icon]} />
      <span className="flex-1">
        {renaming ? <EditorContent editor={editor} className="cursor-text" /> : titleWithFallback(page.title)}
      </span>
      {renaming || disabled ? null : (
        <span onClick={(e) => e.stopPropagation()}>
          <Popover>
            <PopoverTrigger>
              <Icon name="three-dots" />
            </PopoverTrigger>
            <PopoverContent usePortal className="border-0 p-0 shadow-none">
              <div role="menu">
                <div role="menuitem" onClick={() => setRenaming(true)}>
                  <Icon name="pencil" /> Rename
                </div>
                <div className="danger" role="menuitem" onClick={onDelete}>
                  <Icon name="trash2" /> Delete
                </div>
              </div>
            </PopoverContent>
          </Popover>
        </span>
      )}
    </PageListItem>
  );
};
