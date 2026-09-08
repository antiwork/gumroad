// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import { Editor, Node } from "@tiptap/core";
import { NodeSelection } from "@tiptap/pm/state";
import { EditorContent, NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import * as React from "react";
import { afterEach, expect, it } from "vitest";

import { NodeActionsMenu } from "$app/components/TiptapExtensions/NodeActionsMenu";

let editor: Editor;
afterEach(() => {
  cleanup();
  editor.destroy();
});

const FileView = ({ editor, node, getPos }: NodeViewProps) => (
  <NodeViewWrapper data-testid={String(node.attrs.id)} contentEditable={false}>
    <NodeActionsMenu editor={editor} getPos={getPos} />
    {String(node.attrs.id)}
  </NodeViewWrapper>
);
const File = Node.create({
  name: "fileEmbed",
  group: "block",
  atom: true,
  draggable: true,
  addAttributes: () => ({ id: { default: null } }),
  renderHTML: ({ HTMLAttributes }) => ["file-embed", HTMLAttributes],
  addNodeView: () => ReactNodeViewRenderer(FileView),
});
const Folder = Node.create({
  name: "fileEmbedGroup",
  group: "block",
  content: "fileEmbed+",
  renderHTML: () => ["file-embed-group", 0],
});

it("deletes the menu's file after moving another file into a folder, and undo restores it", async () => {
  editor = new Editor({
    extensions: [StarterKit, File, Folder],
    content: {
      type: "doc",
      content: [
        { type: "fileEmbed", attrs: { id: "moved" } },
        { type: "fileEmbed", attrs: { id: "target" } },
        { type: "fileEmbedGroup", content: [{ type: "fileEmbed", attrs: { id: "inside" } }] },
      ],
    },
  });
  const screen = render(<EditorContent editor={editor} />);
  act(() => {
    const moved = editor.state.doc.firstChild;
    if (!moved) throw new Error("missing moved file");
    const tr = editor.state.tr.deleteRange(0, 1);
    tr.insert(3, moved).setSelection(NodeSelection.create(tr.doc, 3));
    editor.view.dispatch(tr);
  });
  const target = screen.getByTestId("target");
  const button = target.querySelector("button");
  if (!button) throw new Error("missing actions button");
  await act(async () => {
    fireEvent.mouseDown(button);
    fireEvent.mouseUp(button);
    fireEvent.click(button);
  });
  await act(async () => {
    fireEvent.click(screen.getByText("Delete"));
  });
  const ids = () => {
    const result: unknown[] = [];
    editor.state.doc.descendants((node) => {
      if (node.type.name === "fileEmbed") result.push(node.attrs.id);
    });
    return result;
  };
  expect(ids()).toEqual(["inside", "moved"]);
  act(() => {
    editor.commands.undo();
  });
  expect(ids()).toEqual(["target", "inside", "moved"]);
});
