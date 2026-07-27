import { describe, expect, it, vi } from "vitest";

import { filesForSave } from "$app/data/product_edit";

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
