import CharacterCount from "@tiptap/extension-character-count";
import Placeholder from "@tiptap/extension-placeholder";
import { EditorContent, useEditor } from "@tiptap/react";
import * as React from "react";

import { generatePageIcon } from "$app/utils/rich_content_page";

import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
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
    <div role="tab" onClick={onClick} aria-selected={selected}>
      {!disabled ? <div aria-grabbed={dragging} /> : null}
      <Icon name={icon} aria-label={iconLabels[icon]} />
      <span className="content">{renaming ? <EditorContent editor={editor} /> : titleWithFallback(page.title)}</span>
      {renaming || disabled ? null : (
        <span onClick={(e) => e.stopPropagation()}>
          <Popover trigger={<Icon name="three-dots" />}>
            <div role="menu">
              <div role="menuitem" onClick={() => setRenaming(true)}>
                <Icon name="pencil" /> Rename
              </div>
              <div className="danger" role="menuitem" onClick={onDelete}>
                <Icon name="trash2" /> Delete
              </div>
            </div>
          </Popover>
        </span>
      )}
    </div>
  );
};
