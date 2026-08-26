// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PICKED_FILE_SNAPSHOT_LIMIT_BYTES } from "$app/utils/snapshotPickedFile";

import { ImageUploadSettings, ImageUploadSettingsContext } from "$app/components/RichTextEditor";
import { Image } from "$app/components/TiptapExtensions/Image";

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: () => {} }));

// happy-dom has no object URL support, and uploadImages mints one per inserted image.
Object.assign(URL, { createObjectURL: () => "blob:picked", revokeObjectURL: () => {} });

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
      return Promise.resolve("https://example.com/uploaded.png");
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
      // snapshotPickedFiles settles on a microtask after the change handler returns
      await Promise.resolve();
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

  it("keeps the original handle and leaves the input alone for an over-budget image", async () => {
    const { input, uploaded } = renderInsertImagePicker();
    const picked = new File(["x"], "huge.png", { type: "image/png" });
    Object.defineProperty(picked, "size", { value: PICKED_FILE_SNAPSHOT_LIMIT_BYTES + 1 });
    const valueWrites = attachPickedFile(input, picked);

    await act(async () => {
      fireEvent.change(input);
      // snapshotPickedFiles settles on a microtask after the change handler returns
      await Promise.resolve();
    });

    expect(uploaded).toEqual([picked]);
    expect(valueWrites).toEqual([]);
  });
});
