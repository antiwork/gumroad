import CharacterCount from "@tiptap/extension-character-count";
import Placeholder from "@tiptap/extension-placeholder";
import { EditorContent, useEditor } from "@tiptap/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { generatePageIcon } from "$app/utils/rich_content_page";

import { PageListItem } from "$app/components/Download/PageListLayout";
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

export const titleWithFallback = (title: string | null | undefined) => (!title?.trim() ? "Chưa đặt tên" : title);

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
      Placeholder.configure({ placeholder: "Đặt tên cho trang của bạn" }),
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
    "file-arrow-down": "Trang có nhiều loại file khác nhau",
    "file-music": "Trang có file âm thanh",
    "file-play": "Trang có video",
    "file-text": "Trang không có file",
    "outline-key": "Trang có mã bản quyền",
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
          <Popover trigger={<Icon name="three-dots" />}>
            <div role="menu">
              <div role="menuitem" onClick={() => setRenaming(true)}>
                <Icon name="pencil" /> Đổi tên
              </div>
              <div className="danger" role="menuitem" onClick={onDelete}>
                <Icon name="trash2" /> Xóa
              </div>
            </div>
          </Popover>
        </span>
      )}
    </PageListItem>
  );
};
