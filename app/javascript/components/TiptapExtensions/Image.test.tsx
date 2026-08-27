// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PICKED_FILE_SNAPSHOT_LIMIT_BYTES } from "$app/utils/snapshotPickedFile";

import { ImageUploadSettings, ImageUploadSettingsContext } from "$app/components/RichTextEditor";
import { Image } from "$app/components/TiptapExtensions/Image";

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: () => {} }));
vi.mock("$app/utils/prepareImageForUpload", () => ({
  isLikelyImageFile: () => false,
  prepareImageForUpload: async (file: File) => file,
  heicDecodingLikely: () => false,
}));

// happy-dom has no object URL support, and uploadImages mints one per inserted image.
let blobSeq = 0;
Object.assign(URL, { createObjectURL: () => `blob:picked-${++blobSeq}`, revokeObjectURL: () => {} });

let editor: Editor | null = null;

afterEach(() => {
  cleanup();
  editor?.destroy();
  editor = null;
});

const attachPickedFile = (input: HTMLInputElement, picked: File) => {
  const valueWrites: string[] = [];
  Object.defineProperty(input, "files", {
    configurable: true,
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- minimal FileList for the handler
    value: {
      length: 1,
      item: (index: number) => (index === 0 ? picked : null),
      [Symbol.iterator]: () => [picked][Symbol.iterator](),
    } as unknown as FileList,
  });
  Object.defineProperty(input, "value", {
    configurable: true,
    get: () => "",
    set: (value: string) => valueWrites.push(value),
  });
  return valueWrites;
};

// menuItem() is a hook-using component body, so it has to run during a render. Its MenuItem
// sibling reads toolbar-only tooltip context and would throw here, so mount just the picker.
const InsertImagePicker = ({ editor: mounted }: { editor: Editor }) => {
  const rendered = Image.config.menuItem?.(mounted);
  const children = React.isValidElement<{ children?: React.ReactNode }>(rendered) ? rendered.props.children : null;
  return (
    <>{React.Children.toArray(children).filter((child) => React.isValidElement(child) && child.type === "input")}</>
  );
};

const renderInsertImagePicker = () => {
  const uploaded: File[] = [];
  // uploadImages goes through editor.view, which only exists once the editor is mounted.
  const element = document.createElement("div");
  document.body.append(element);
  editor = new Editor({ element, extensions: [StarterKit, Image], content: "<p>hello</p>" });

  const imageSettings: ImageUploadSettings = {
    allowedExtensions: ["png", "jpg"],
    onUpload: (file) => {
      uploaded.push(file);
      return Promise.resolve(`https://example.com/${file.name}`);
    },
  };
  render(
    <ImageUploadSettingsContext.Provider value={imageSettings}>
      <InsertImagePicker editor={editor} />
    </ImageUploadSettingsContext.Provider>,
  );
  const input = document.querySelector<HTMLInputElement>('input[type="file"]');
  if (!input) throw new Error("Insert image file input did not mount");
  return { input, uploaded };
};

describe("Insert image picker", () => {
  it("uploads a snapshot copy of a small picked image and resets the input", async () => {
    const { input, uploaded } = renderInsertImagePicker();
    const picked = new File(["png-bytes"], "pic.png", { type: "image/png" });
    const valueWrites = attachPickedFile(input, picked);

    await act(async () => {
      fireEvent.change(input);
    });
    await waitFor(() => {
      if (!uploaded[0]) throw new Error("onUpload was not called");
    });

    const [file] = uploaded;
    if (!file) throw new Error("onUpload was not called");
    // A copy must be uploaded, not the picked File: resetting the input revokes the
    // original's backing in Chromium, stranding the upload at 0%.
    expect(file).not.toBe(picked);
    expect(file.name).toBe("pic.png");
    expect(file.size).toBe(picked.size);
    expect(await file.text()).toBe("png-bytes");
    expect(valueWrites).toEqual([""]);
  });

  it("keeps the original handle until upload settles, then resets an over-budget image", async () => {
    const { input, uploaded } = renderInsertImagePicker();
    const picked = new File(["x"], "huge.png", { type: "image/png" });
    Object.defineProperty(picked, "size", { value: PICKED_FILE_SNAPSHOT_LIMIT_BYTES + 1 });
    const valueWrites = attachPickedFile(input, picked);

    await act(async () => {
      fireEvent.change(input);
    });
    await waitFor(() => expect(uploaded).toEqual([picked]));
    expect(valueWrites).toEqual([""]);
  });

  it("resets the input when snapshotting the pick fails", async () => {
    const { input, uploaded } = renderInsertImagePicker();
    const picked = new File(["png"], "pic.png", { type: "image/png" });
    Object.defineProperty(picked, "arrayBuffer", { value: () => Promise.reject(new Error("read failed")) });
    const valueWrites = attachPickedFile(input, picked);

    await act(async () => {
      fireEvent.change(input);
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(uploaded).toEqual([]);
    expect(valueWrites).toEqual([""]);
  });

  it("maps the insert position across edits while the snapshot is in flight", async () => {
    const { input } = renderInsertImagePicker();
    let release!: () => void;
    const ready = new Promise<ArrayBuffer>((resolve) => {
      release = () => resolve(new TextEncoder().encode("png").buffer);
    });
    const picked = new File(["png"], "pic.png", { type: "image/png" });
    Object.defineProperty(picked, "arrayBuffer", { value: () => ready });
    attachPickedFile(input, picked);

    act(() => {
      fireEvent.change(input);
    });

    // Delete the paragraph contents so a stale insertAt is out of range.
    act(() => {
      if (!editor) throw new Error("editor missing");
      editor.chain().setTextSelection({ from: 1, to: 6 }).deleteSelection().run();
    });

    await act(async () => {
      release();
      await ready;
    });
    await waitFor(() => {
      const images: unknown[] = [];
      editor?.state.doc.descendants((node) => {
        if (node.type.name === "image") images.push(node);
      });
      expect(images).toHaveLength(1);
    });
  });

  it("inserts multiple images in selection order", async () => {
    const { input } = renderInsertImagePicker();
    const first = new File(["a"], "a.png", { type: "image/png" });
    const second = new File(["b"], "b.png", { type: "image/png" });
    const picked = [first, second];
    Object.defineProperty(input, "files", {
      configurable: true,
      // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- minimal FileList for the handler
      value: {
        length: picked.length,
        item: (index: number) => picked[index] ?? null,
        [Symbol.iterator]: () => picked[Symbol.iterator](),
      } as unknown as FileList,
    });

    await act(async () => {
      fireEvent.change(input);
    });
    await waitFor(() => {
      const names: string[] = [];
      editor?.state.doc.descendants((node) => {
        if (node.type.name === "image") names.push(String(node.attrs.src));
      });
      expect(names).toEqual(["https://example.com/a.png", "https://example.com/b.png"]);
    });
  });

  it("rejects a file the editor does not allow", async () => {
    const { input, uploaded } = renderInsertImagePicker();
    const picked = new File(["<svg></svg>"], "logo.svg", { type: "image/svg+xml" });
    const valueWrites = attachPickedFile(input, picked);

    await act(async () => {
      fireEvent.change(input);
    });
    await waitFor(() => expect(valueWrites).toEqual([""]));
    expect(uploaded).toEqual([]);
  });
});
