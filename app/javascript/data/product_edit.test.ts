import { history, undo } from "@tiptap/pm/history";
import { Schema } from "@tiptap/pm/model";
import { EditorState, TextSelection } from "@tiptap/pm/state";
import { describe, expect, it, vi } from "vitest";

import {
  buildRichContentReconciliationTransaction,
  filesForSave,
  removeFileEmbedsFromRichContent,
} from "$app/data/product_edit";

vi.mock("@tiptap/core", () => ({
  Editor: class {
    schema = { nodeFromJSON: () => ({}) };
    destroy() {}
  },
  findChildren: () => [],
}));
vi.mock("$app/components/ProductEdit/ContentTab", () => ({ extensions: () => [] }));
vi.mock("$app/components/ProductEdit/ContentTab/FileEmbed", () => ({ FileEmbed: { name: "fileEmbed" } }));
vi.mock("$app/components/RichTextEditor", () => ({ baseEditorOptions: () => ({}) }));

describe("filesForSave", () => {
  it("does not remove files from editor state before a hidden-content conflict retry", () => {
    const file = { id: "file-id" };
    const editorFiles = [file];

    expect(filesForSave(editorFiles, new Set(), false)).toEqual([]);
    expect(editorFiles).toEqual([file]);
    expect(filesForSave(editorFiles, new Set(), true)).toEqual([file]);
  });
});

describe("removeFileEmbedsFromRichContent", () => {
  it("removes reported embeds, prunes empty groups, and preserves other content", () => {
    const description = {
      type: "doc",
      content: [
        { type: "fileEmbed", attrs: { id: "keep", uid: "keep-uid" } },
        {
          type: "fileEmbedGroup",
          attrs: { uid: "mixed-group" },
          content: [
            { type: "fileEmbed", attrs: { id: "remove", uid: "remove-uid" } },
            { type: "fileEmbed", attrs: { id: "keep", uid: "keep-group-uid" } },
          ],
        },
        {
          type: "fileEmbedGroup",
          attrs: { uid: "empty-group" },
          content: [{ type: "fileEmbed", attrs: { id: "remove", uid: "remove-group-uid" } }],
        },
        { type: "paragraph", content: [{ type: "text", text: "Keep this edit" }] },
      ],
    };

    expect(removeFileEmbedsFromRichContent(description, new Set(["remove"]))).toEqual({
      type: "doc",
      content: [
        { type: "fileEmbed", attrs: { id: "keep", uid: "keep-uid" } },
        {
          type: "fileEmbedGroup",
          attrs: { uid: "mixed-group" },
          content: [{ type: "fileEmbed", attrs: { id: "keep", uid: "keep-group-uid" } }],
        },
        { type: "paragraph", content: [{ type: "text", text: "Keep this edit" }] },
      ],
    });
  });

  it("keeps the mounted-editor cleanup out of undo history", () => {
    const schema = new Schema({
      nodes: {
        doc: { content: "block+" },
        paragraph: { group: "block", content: "text*" },
        text: {},
        fileEmbedGroup: {
          group: "block",
          content: "fileEmbed+",
          attrs: { uid: {} },
        },
        fileEmbed: {
          atom: true,
          attrs: { id: { default: null }, uid: { default: null } },
        },
      },
    });
    const originalDocument = schema.nodeFromJSON({
      type: "doc",
      content: [
        {
          type: "fileEmbedGroup",
          attrs: { uid: "stale-group" },
          content: [{ type: "fileEmbed", attrs: { id: "remove", uid: "stale-uid" } }],
        },
        { type: "paragraph", content: [{ type: "text", text: "First edit" }] },
      ],
    });
    let state = EditorState.create({
      doc: originalDocument,
      plugins: [history()],
    });
    const removedGroupSize = originalDocument.child(0).nodeSize;
    const textStart = removedGroupSize + 1;
    const typedText = " pending";
    const caretBeforeCleanup = textStart + "First".length + typedText.length;
    const editTransaction = state.tr.insertText(typedText, textStart + "First".length);
    editTransaction.setSelection(TextSelection.create(editTransaction.doc, caretBeforeCleanup));
    state = state.apply(editTransaction);
    const cleanedDocument = schema.nodeFromJSON({
      type: "doc",
      content: [{ type: "paragraph", content: [{ type: "text", text: "First pending edit" }] }],
    });
    const transaction = buildRichContentReconciliationTransaction(state, new Set(["remove"]));

    expect(transaction.getMeta("addToHistory")).toBe(false);
    expect(transaction.getMeta("preventUpdate")).toBe(true);

    const reconciledState = state.apply(transaction);
    expect(reconciledState.doc.toJSON()).toEqual(cleanedDocument.toJSON());
    expect(reconciledState.selection.from).toBe(caretBeforeCleanup - removedGroupSize);

    let undoneState = reconciledState;
    expect(
      undo(reconciledState, (undoTransaction) => {
        undoneState = reconciledState.apply(undoTransaction);
      }),
    ).toBe(true);
    expect(undoneState.doc.toJSON()).toEqual({
      type: "doc",
      content: [{ type: "paragraph", content: [{ type: "text", text: "First edit" }] }],
    });
  });
});
