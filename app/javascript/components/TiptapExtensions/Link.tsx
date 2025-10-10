import { Editor, Node } from "@tiptap/core";
import { Link as BaseLink } from "@tiptap/extension-link";
import { NodeSelection, Selection, TextSelection } from "@tiptap/pm/state";
import { NodeViewContent, NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import cx from "classnames";
import * as React from "react";
import { createPortal } from "react-dom";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { Popover } from "$app/components/Popover";
import { MenuItem, validateUrl } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";

export const WithDialog = ({
  editor,
  type,
  children,
}: {
  editor: Editor;
  type: "link" | "button";
  children: React.ReactNode;
}) => {
  const [addingLink, setAddingLink] = React.useState<{ label: string; url: string } | null>(null);
  const labelInputRef = React.useRef<HTMLInputElement | null>(null);
  const linkInputRef = React.useRef<HTMLInputElement | null>(null);

  React.useEffect(() => {
    if (addingLink !== null) {
      setTimeout(() => labelInputRef.current?.focus(), 0);
    }
  }, [addingLink?.label]);

  React.useEffect(() => {
    if (type === "link" && (addingLink?.label !== "" || editor.isActive("image"))) {
      setTimeout(() => linkInputRef.current?.focus(), 0);
    }
  }, [addingLink?.url]);

  const onLinkMenuItemClick = () => {
    const { from, to, empty } = editor.view.state.selection;
    const label = empty ? "" : editor.state.doc.textBetween(from, to, "");
    if (editor.getAttributes("image").link) {
      editor.chain().updateAttributes("image", { link: null }).run();
    } else {
      setAddingLink({ label, url: "" });
    }
  };

  const onAddLink = () => {
    if (!addingLink) return;

    const href = validateUrl(addingLink.url);
    if (!href) {
      showAlert("Please enter a valid URL.", "error");
      return;
    }
    const chain = editor.chain().focus();
    const label = addingLink.label || href || "";
    if (type === "button") {
      chain.insertContent({
        type,
        attrs: { href },
        content: [
          {
            type: "text",
            text: label,
          },
        ],
      });
    } else if (editor.isActive("image")) chain.updateAttributes("image", { link: href.toString() });
    else if (!editor.isActive("button") && !editor.isActive("codeBlock")) {
      chain.insertContent({
        type: Link.name,
        attrs: { href },
        content: [
          {
            type: "text",
            text: label,
          },
        ],
      });
    }
    chain.run();
    setAddingLink(null);
  };

  return (
    <>
      {addingLink !== null
        ? // TODO (maya) remove this once popovers no longer use details
          createPortal(
            <Modal open onClose={() => setAddingLink(null)} title={`Insert ${type === "link" ? "link" : "button"}`}>
              {!editor.isActive("image") ? (
                <input
                  ref={labelInputRef}
                  type="text"
                  placeholder="Enter text"
                  value={addingLink.label}
                  onChange={(el) => setAddingLink({ label: el.target.value, url: addingLink.url || "" })}
                  onKeyDown={(el) => {
                    if (el.key === "Enter") onAddLink();
                  }}
                />
              ) : null}
              <input
                ref={linkInputRef}
                type="text"
                placeholder="Enter URL"
                value={addingLink.url}
                onChange={(el) => setAddingLink({ label: addingLink.label || "", url: el.target.value })}
                onKeyDown={(el) => {
                  if (el.key === "Enter") onAddLink();
                }}
              />
              <Button color="primary" onClick={onAddLink}>
                {type === "link" ? "Add link" : "Add button"}
              </Button>
            </Modal>,
            document.body,
          )
        : null}
      <div onClick={onLinkMenuItemClick}>{children}</div>
    </>
  );
};

const LinkNodeView = ({ node, editor, getPos, deleteNode }: NodeViewProps) => {
  const [isPopoverShown, setIsPopoverShown] = React.useState(false);
  const [isPopoverVisible, setIsPopoverVisible] = React.useState(false);
  const [link, setLink] = React.useState<{ label: string; url: string }>({
    label: node.textContent,
    url: cast(node.attrs.href),
  });

  const linkInputRef = React.useRef<HTMLInputElement | null>(null);
  const isButton = node.type.name === TiptapButton.name;

  const handleSave = () => {
    const href = validateUrl(link.url);
    if (link.label.trim() === "") return;
    if (!href) {
      linkInputRef.current?.focus();
      return showAlert("Please enter a valid URL.", "error");
    }
    const markStartPos = getPos() + 1;
    editor
      .chain()
      .focus()
      .setNodeSelection(getPos())
      .insertContent({
        type: node.type.name,
        attrs: { href },
        content: [{ type: "text", text: link.label }],
      })
      .command(({ tr }) => {
        // Retain original marks if the button label is unchanged
        if (node.textContent === link.label) {
          node.forEach((child, offset) => {
            child.marks.forEach((mark) => {
              tr.addMark(markStartPos + offset, markStartPos + offset + child.textContent.length, mark);
            });
          });
        }
        // Retain the earlier applied only mark, if any
        else if (node.childCount === 1) {
          node.child(0).marks.forEach((mark) => {
            tr.addMark(markStartPos, markStartPos + link.label.length, mark);
          });
        }
        tr.setMeta("addToHistory", false);
        return true;
      })
      .setMeta("addToHistory", true)
      .run();
    setLink({ ...link, url: href });
    setIsPopoverShown(false);
    editor.commands.setTextSelection(editor.state.selection.to);
  };

  const removeLink = (event: React.MouseEvent) => {
    event.preventDefault();
    editor
      .chain()
      .focus()
      .setNodeSelection(getPos())
      .command(({ tr }) => {
        tr.deleteSelection();
        tr.insertText(node.textContent);
        return true;
      })
      .run();
  };

  const handleKeyPress = (evt: React.KeyboardEvent<HTMLInputElement>) => {
    if (evt.key === "Enter") handleSave();
  };

  React.useEffect(() => {
    if (isPopoverShown) {
      requestAnimationFrame(() => setIsPopoverVisible(true));
    } else {
      setIsPopoverVisible(false);
    }
  }, [isPopoverShown]);

  React.useEffect(() => {
    if (isPopoverVisible) {
      linkInputRef.current?.focus();
    }
  }, [isPopoverVisible]);

  React.useEffect(() => {
    if (node.textContent.trim() === "") queueMicrotask(() => getPos() && deleteNode());
  }, [node.textContent]);

  return (
    <NodeViewWrapper as="span" style={{ display: "inline-block" }}>
      {editor.isEditable && (isPopoverShown || isButton) ? (
        <Popover
          trigger={
            <NodeViewContent
              as="a"
              href={cast<string>(node.attrs.href)}
              className={cx({ "button primary": isButton })}
              target="_blank"
              rel="noopener noreferrer nofollow"
            />
          }
          open={isPopoverShown}
          onToggle={() => {
            setLink({ label: node.textContent, url: cast(node.attrs.href) });
            setIsPopoverShown(!isPopoverShown);
          }}
          style={{ visibility: isButton || isPopoverVisible ? "visible" : "hidden" }}
        >
          <fieldset>
            <input
              placeholder="Enter text"
              value={link.label}
              onChange={(evt) => setLink({ ...link, label: evt.target.value })}
              onKeyDown={handleKeyPress}
            />
            <input
              placeholder="Enter URL"
              value={link.url}
              ref={linkInputRef}
              onChange={(evt) => setLink({ ...link, url: evt.target.value })}
              onKeyDown={handleKeyPress}
            />
            <div className="input-with-button">
              {!isButton && (
                <Button contentEditable={false} color="danger" onClick={removeLink}>
                  Remove link
                </Button>
              )}
              <Button
                contentEditable={false}
                color="primary"
                onClick={handleSave}
                disabled={(link.url === node.attrs.href && link.label === node.textContent) || link.label.trim() === ""}
              >
                Save
              </Button>
            </div>
          </fieldset>
        </Popover>
      ) : (
        <NodeViewContent
          style={{ display: "grid" }}
          as="a"
          href={cast<string>(node.attrs.href)}
          contentEditable={editor.isEditable}
          className={cx({ "button primary": isButton })}
          target="_blank"
          rel="noopener noreferrer nofollow"
          onClick={(event: React.MouseEvent) => {
            if (editor.isEditable) {
              event.preventDefault();
              setLink({ label: node.textContent, url: cast(node.attrs.href) });
              setIsPopoverShown(true);
            }
          }}
        />
      )}
    </NodeViewWrapper>
  );
};

const TiptapButton = Node.create({
  name: "button",
  isolating: true,
  draggable: true,
  group: "block",
  content: "inline+",
  addAttributes: () => ({ href: { default: null } }),
  parseHTML: () => [{ tag: "a[href].tiptap__button" }],
  renderHTML({ HTMLAttributes }) {
    return [
      "a",
      {
        ...HTMLAttributes,
        class: "tiptap__button button primary",
        target: "_blank",
        rel: "noopener noreferrer nofollow",
      },
      0,
    ];
  },
  addNodeView() {
    return ReactNodeViewRenderer(LinkNodeView);
  },
  menuItem: (editor) => (
    <WithDialog editor={editor} type="button">
      <MenuItem name="Insert button" icon="button" />
    </WithDialog>
  ),
  submenu: {
    menu: "insert",
    item: (editor) => (
      <WithDialog editor={editor} type="button">
        <div role="menuitem">
          <Icon name="button" />
          <span>Button</span>
        </div>
      </WithDialog>
    ),
  },
});
export { TiptapButton as Button };

export const LinkMenuItem = ({ editor }: { editor: Editor }) => (
  <WithDialog editor={editor} type="link">
    <MenuItem name="Insert link" icon="link" active={editor.isActive("link") || !!editor.getAttributes("image").link} />
  </WithDialog>
);

export const Link = Node.create({
  name: "tiptap-link",
  group: "inline",
  inline: true,
  isolating: true,
  content: "text*",
  addAttributes: () => ({ href: { default: null } }),
  parseHTML: () => [{ tag: "a[href]:not(.tiptap__button)" }],
  renderHTML({ HTMLAttributes }) {
    return [
      "a",
      {
        ...HTMLAttributes,
        target: "_blank",
        rel: "noopener noreferrer nofollow",
      },
      0,
    ];
  },
  addNodeView() {
    return ReactNodeViewRenderer(LinkNodeView);
  },
  addKeyboardShortcuts() {
    const handleModDelete = (editor: Editor) =>
      editor.commands.command(({ tr, dispatch, state }) => {
        if (editor.isActive("codeBlock")) return false;
        const { $head } = state.selection;
        const parentStartsWithLink = $head.parent.firstChild?.type.name === Link.name;
        const nodeBeforeCursor = state.doc.nodeAt($head.pos - 1);
        // Fixes an issue where it does not delete the line on "Mod-Delete" when the parent (such as a paragraph) starts with a link.
        if (dispatch && parentStartsWithLink && nodeBeforeCursor?.isText) {
          tr.setSelection(
            TextSelection.create(state.doc, $head.pos - (nodeBeforeCursor.text?.length ?? 0) - 1, $head.pos),
          );
          dispatch(tr.deleteSelection());
          return true;
        }
        return false;
      });
    const handleVerticalMovement = (editor: Editor, direction: "up" | "down") =>
      editor.commands.command(({ tr, dispatch, state }) => {
        if (state.selection.empty && dispatch) {
          const { $head } = state.selection;
          // Fixes the vertical arrow movement when the cursor is inside a link (it does not move, otherwise).
          if ($head.parent.type.name === Link.name) {
            const nextPosOffset = direction === "up" ? -$head.parentOffset - 1 : $head.parent.content.size + 1;
            const nextPos =
              direction === "up"
                ? Math.max(0, $head.pos + nextPosOffset)
                : Math.min(state.doc.content.size, $head.pos + nextPosOffset);
            dispatch(tr.setSelection(Selection.near(state.doc.resolve(nextPos))));
            return true;
          }
        }
        return false;
      });

    return {
      Enter: ({ editor }) => {
        if (!editor.isActive(Link.name)) return false;
        return editor.commands.insertContent({ type: "hardBreak" });
      },
      ArrowUp: ({ editor }) => handleVerticalMovement(editor, "up"),
      ArrowDown: ({ editor }) => handleVerticalMovement(editor, "down"),
      "Mod-Backspace": ({ editor }) => handleModDelete(editor),
      "Mod-Delete": ({ editor }) => handleModDelete(editor),
    };
  },
  menuItem: (editor) => <LinkMenuItem editor={editor} />,
  onSelectionUpdate() {
    // Replace all text nodes having the "link" mark with the "tiptap-link" node
    if (!this.editor.isActive("link")) return;

    const tr = this.editor.state.tr;
    const originalSelectionPos = tr.selection.from;
    this.editor.state.doc.descendants((node, pos) => {
      if (node.isText && node.marks.some((mark) => mark.type.name === "link")) {
        const link = node.marks.find((mark) => mark.type.name === "link");
        if (link) {
          const mappedPos = tr.mapping.map(pos);
          const href = cast(link.attrs.href);
          const LinkNode =
            this.editor.schema.nodes[Link.name]?.create({ href }, this.editor.schema.text(node.text || "")) ?? node;
          tr.setSelection(new NodeSelection(tr.doc.resolve(mappedPos)));
          tr.deleteSelection();
          tr.insert(mappedPos, LinkNode);
        }
      }
    });

    this.editor.view.dispatch(
      tr
        .setSelection(new TextSelection(tr.doc.resolve(tr.mapping.map(originalSelectionPos))))
        .scrollIntoView()
        .setMeta("addToHistory", false),
    );
  },
  addExtensions: () => [BaseLink.extend({ parseHTML: () => undefined }).configure({ openOnClick: false })],
});
