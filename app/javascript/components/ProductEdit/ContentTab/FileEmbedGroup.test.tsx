// @vitest-environment happy-dom
import { act, cleanup, render } from "@testing-library/react";
import { Fragment, Slice } from "@tiptap/pm/model";
import { NodeSelection } from "@tiptap/pm/state";
import type { EditorView } from "@tiptap/pm/view";
import { EditorContent, type Editor, useEditor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { cast } from "$app/utils/cast";

import { FileEmbed } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { FileEmbedGroup } from "$app/components/ProductEdit/ContentTab/FileEmbedGroup";
import { FileEntry } from "$app/components/ProductEdit/state";

vi.mock("@rails/activestorage", () => ({
  DirectUpload: class {
    create(callback: (error: Error | null, blob: { key: string; signed_id: string }) => void) {
      callback(null, { key: "thumb-key", signed_id: "thumb-signed-id" });
    }
  },
}));

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: () => {} }));

// vite.config.ts replaces the bare `SSR` identifier at build time.
Object.assign(globalThis, { SSR: false });
Object.assign(globalThis, {
  Routes: {
    download_product_files_path: (productId: string, options: { product_file_ids: string[] }) =>
      `/products/${productId}/download?product_file_ids=${options.product_file_ids.join(",")}`,
  },
});

const context = vi.hoisted(() => ({
  id: "product-id",
  updateProduct: (_update: unknown) => {},
  filesById: new Map<string, FileEntry>(),
}));

vi.mock("$app/components/ProductEdit/state", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/ProductEdit/state")>();
  return { ...mod, useProductEditContext: () => context };
});

vi.mock("$app/components/EvaporateUploader", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/EvaporateUploader")>();
  return { ...mod, useEvaporateUploader: () => ({ scheduleUpload: () => 0, cancelUpload: () => {} }) };
});

vi.mock("$app/components/S3UploadConfig", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/S3UploadConfig")>();
  return {
    ...mod,
    useS3UploadConfig: () => ({
      generateS3KeyForUpload: (guid: string, name: string) => ({
        s3key: `key-${guid}`,
        fileUrl: `s3://${guid}/${name}`,
      }),
    }),
  };
});

// Pin the rows visible so their drop handlers are mounted.
vi.mock("$app/components/ProductEdit/ContentTab/useNodeVisibility", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/ProductEdit/ContentTab/useNodeVisibility")>();
  const react = await import("react");
  return { ...mod, useNodeVisibility: () => ({ ref: react.useRef(null), visible: true, lastHeight: { current: 82 } }) };
});

afterEach(() => cleanup());

const FILE_A = "file-a";
const FILE_B = "file-b";
const FILE_C = "file-c";
const FOLDER_UID = "uid-folder";

const file = (id: string, displayName: string): FileEntry =>
  cast<FileEntry>({
    id,
    display_name: displayName,
    description: null,
    extension: "ZIP",
    file_size: 1024,
    is_pdf: false,
    pdf_stamp_enabled: false,
    hide_kindle_and_read_buttons: false,
    is_streamable: false,
    stream_only: false,
    is_transcoding_in_progress: false,
    url: null,
    subtitle_files: [],
    status: { type: "unsaved", uploadStatus: { type: "uploaded" }, url: `blob:${id}` },
    thumbnail: null,
  });

const setUpFiles = () => {
  const map = new Map<string, FileEntry>([
    [FILE_A, file(FILE_A, "first")],
    [FILE_B, file(FILE_B, "second")],
    [FILE_C, file(FILE_C, "third")],
  ]);
  context.filesById = map;
  return map;
};

const Rows = ({ initialContent }: { initialContent: object }) => {
  const mounted = useEditor({
    extensions: [
      StarterKit.configure({ dropcursor: false }),
      FileEmbed.configure({ getConfig: () => ({ filesById: context.filesById, onUploadCancelled: () => {} }) }),
      FileEmbedGroup.configure({
        getConfig: () => ({
          productId: "product-id",
          variantId: null,
          prepareDownload: () => Promise.resolve(),
          filesById: context.filesById,
        }),
      }),
    ],
    content: initialContent,
    immediatelyRender: false,
  });
  React.useEffect(() => {
    editorRef(mounted);
  });
  return <EditorContent editor={mounted} />;
};

let editorRef = (_editor: Editor | null) => {};
const mount = async (initialContent: object) => {
  setUpFiles();
  let editor: Editor | null = null;
  editorRef = (mounted) => {
    editor = mounted ?? editor;
  };
  render(<Rows initialContent={initialContent} />);
  await act(() => Promise.resolve());
  return cast<Editor>(editor);
};

const fileEmbedPos = (editor: Editor, id: string) => {
  let found = -1;
  editor.state.doc.descendants((node, pos) => {
    if (found < 0 && node.type.name === "fileEmbed" && node.attrs.id === id) found = pos;
  });
  return found;
};

const row = (id: string, uid: string) => ({ type: "fileEmbed", attrs: { id, uid } });

// A row the seller drops another row onto offers to group the two, so the cursor has to be away
// from its edges for the row to accept the drop (see shouldIgnoreFileGroupingAt).
const giveRowHeight = (element: Element) =>
  Object.defineProperty(element, "getBoundingClientRect", {
    value: () => ({ top: 0, bottom: 100, left: 0, right: 0, width: 100, height: 100, x: 0, y: 0, toJSON: () => ({}) }),
  });

describe("dragging a file onto another file's row", () => {
  it("moves both rows into one new folder and leaves the rows below them alone", async () => {
    const editor = await mount({
      type: "doc",
      content: [row(FILE_A, "uid-a"), row(FILE_B, "uid-b"), row(FILE_C, "uid-c")],
    });
    const draggedPos = fileEmbedPos(editor, FILE_A);
    const targetPos = fileEmbedPos(editor, FILE_B);
    const dragged = editor.state.doc.resolve(draggedPos).nodeAfter;
    if (!dragged) throw new Error("no dragged node");

    editor.commands.setNodeSelection(draggedPos);
    // What ProseMirror records at dragstart: the slice, the move flag and the node it will
    // move. Its declared type omits the node, but the drop handler reads it.
    const dragging = {
      slice: new Slice(Fragment.from(dragged), 0, 0),
      move: true,
      node: NodeSelection.create(editor.state.doc, draggedPos),
    };
    editor.view.dragging = dragging;
    vi.spyOn(editor.view, "posAtCoords").mockReturnValue({ pos: targetPos, inside: -1 });
    const target = cast<HTMLElement>(editor.view.nodeDOM(targetPos));
    giveRowHeight(target);
    // The wrapper is what a real drag event lands on; dispatching at the node view's container
    // instead would never reach the row's React handlers.
    const rowEl = target.querySelector("[data-node-view-wrapper]") ?? target;
    giveRowHeight(rowEl);

    const dragover = new Event("dragover", { bubbles: true, cancelable: true });
    Object.assign(dragover, { clientY: 50, dataTransfer: { getData: () => "", files: [], types: ["text/html"] } });
    act(() => {
      rowEl.dispatchEvent(dragover);
    });

    const drop = new Event("drop", { bubbles: true, cancelable: true });
    Object.assign(drop, { clientY: 50, dataTransfer: { getData: () => "", files: [], types: ["text/html"] } });
    act(() => {
      rowEl.dispatchEvent(drop);
    });
    // A browser keeps bubbling the same event up to the editor's DOM after the row's handler
    // returns, unless that handler stopped it. ProseMirror's own drop listener is there.
    if (!drop.defaultPrevented) {
      act(() => {
        editor.view.dom.dispatchEvent(drop);
      });
    }

    const content = editor.getJSON().content ?? [];
    expect(content.map((node) => node.type)).toEqual(["fileEmbedGroup", "fileEmbed"]);
    expect(content[0]?.content?.map((node) => cast<string>(node.attrs?.id))).toEqual([FILE_B, FILE_A]);
    expect(content[1]?.attrs?.id).toEqual(FILE_C);
  });
});

describe("a folder arriving as a copy", () => {
  it("gives the copy a uid of its own", async () => {
    const editor = await mount({
      type: "doc",
      content: [
        {
          type: "fileEmbedGroup",
          attrs: { uid: FOLDER_UID, name: "Earlier Versions" },
          content: [row(FILE_A, "uid-a")],
        },
        row(FILE_B, "uid-b"),
      ],
    });

    const original = editor.state.doc.child(0);
    // What a drag or paste from outside the editor offers: the folder's shape, but a node of its
    // own. ProseMirror runs every incoming slice through this prop before it is inserted.
    const copy = original.type.create(original.attrs, original.content, original.marks);
    const slice = new Slice(Fragment.from(copy), 0, 0);
    const transform = cast<((s: Slice, view: EditorView) => Slice) | undefined>(
      editor.view.someProp("transformPasted"),
    );
    if (!transform) throw new Error("no transformPasted registered");

    const copied = transform(slice, editor.view).content.firstChild;
    expect(original.attrs.uid).toEqual(FOLDER_UID);
    expect(copied?.attrs.uid).not.toEqual(null);
    expect(copied?.attrs.uid).not.toEqual(FOLDER_UID);
  });
});

describe("a folder moved with the rows around it", () => {
  it("keeps its uid, so the folder's own download link survives the move", async () => {
    const editor = await mount({
      type: "doc",
      content: [
        row(FILE_A, "uid-a"),
        {
          type: "fileEmbedGroup",
          attrs: { uid: FOLDER_UID, name: "Earlier Versions" },
          content: [row(FILE_B, "uid-b")],
        },
      ],
    });
    editor.commands.setTextSelection({ from: 0, to: editor.state.doc.content.size });
    // ProseMirror serializes a dragged selection through `transformCopied`, which reparses the
    // slice, so the folder the drop carries is a new object that already holds its uid.
    const dataTransfer = {
      files: [],
      types: ["text/html"],
      html: "",
      text: "",
      setData: (type: string, value: string) => {
        if (type === "text/html") dataTransfer.html = value;
        else dataTransfer.text = value;
      },
      getData: (type: string) => (type === "text/html" ? dataTransfer.html : dataTransfer.text),
      clearData: () => {},
      setDragImage: () => {},
      effectAllowed: "copyMove",
      dropEffect: "move",
    };
    vi.spyOn(editor.view, "posAtCoords").mockReturnValue({ pos: 3, inside: -1 });

    const dragstart = new Event("dragstart", { bubbles: true, cancelable: true });
    Object.assign(dragstart, { dataTransfer, altKey: false, ctrlKey: false, clientX: 5, clientY: 5 });
    act(() => {
      editor.view.dom.dispatchEvent(dragstart);
    });
    // What ProseMirror records at dragstart for a plain drag: the reparsed slice and the move flag.
    const dragging = editor.view.dragging;
    expect(dragging?.move).toEqual(true);
    expect(dragging?.slice.content.lastChild).not.toBe(editor.state.doc.child(1));

    vi.spyOn(editor.view, "posAtCoords").mockReturnValue({ pos: editor.state.doc.content.size, inside: -1 });
    const drop = new Event("drop", { bubbles: true, cancelable: true });
    Object.assign(drop, { dataTransfer, clientX: 5, clientY: 5 });
    act(() => {
      editor.view.dom.dispatchEvent(drop);
    });

    const folders = (editor.getJSON().content ?? []).filter((node) => node.type === "fileEmbedGroup");
    expect(folders).toHaveLength(1);
    expect(folders[0]?.attrs?.uid).toEqual(FOLDER_UID);
    expect(folders[0]?.content?.map((node) => cast<string>(node.attrs?.id))).toEqual([FILE_B]);
  });
});
