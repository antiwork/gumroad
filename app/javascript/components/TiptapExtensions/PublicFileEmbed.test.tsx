// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PublicFilesSettingsContext } from "$app/components/ProductEdit/ProductTab/DescriptionEditor";
import { PublicFileEmbed } from "$app/components/TiptapExtensions/PublicFileEmbed";

const alerts = vi.hoisted((): { message: string; level: string }[] => []);
vi.mock("$app/components/server-components/Alert", () => ({
  showAlert: (message: string, level: string) => alerts.push({ message, level }),
}));

let editor: Editor | null = null;

afterEach(() => {
  cleanup();
  editor?.destroy();
  editor = null;
  alerts.length = 0;
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

// menuItem() uses hooks, so invoke it inside a rendered component. Mount only
// the hidden picker to avoid toolbar-only MenuItem context requirements.
const PublicFilePicker = ({ mountedEditor }: { mountedEditor: Editor }) => {
  const rendered = PublicFileEmbed.config.menuItem?.(mountedEditor);
  const children = React.isValidElement<{ children?: React.ReactNode }>(rendered) ? rendered.props.children : null;

  return (
    <>{React.Children.toArray(children).filter((child) => React.isValidElement(child) && child.type === "input")}</>
  );
};

describe("PublicFileEmbed picker", () => {
  it("uploads a snapshot copy of a picked audio file before resetting the input", async () => {
    const element = document.createElement("div");
    document.body.append(element);

    editor = new Editor({
      element,
      extensions: [StarterKit, PublicFileEmbed],
      content: "<p>hello</p>",
    });

    const uploaded: File[] = [];

    render(
      <PublicFilesSettingsContext.Provider
        value={{
          files: [],
          onUpload: ({ file }) => {
            uploaded.push(file);
          },
        }}
      >
        <PublicFilePicker mountedEditor={editor} />
      </PublicFilesSettingsContext.Provider>,
    );

    const input = document.querySelector<HTMLInputElement>('input[type="file"]');
    if (!input) throw new Error("Public file input did not mount");

    const picked = new File(["audio-bytes"], "preview.mp3", {
      type: "audio/mpeg",
    });
    const valueWrites = attachPickedFile(input, picked);

    await act(async () => {
      fireEvent.change(input);
      await Promise.resolve();
    });

    const [file] = uploaded;
    if (!file) throw new Error("onUpload was not called");

    // Resetting a file input can revoke the browser-owned File backing in
    // Chromium. The upload must receive an independent snapshot.
    expect(file).not.toBe(picked);
    expect(file.name).toBe("preview.mp3");
    expect(file.size).toBe(picked.size);
    expect(await file.text()).toBe("audio-bytes");
    expect(valueWrites).toEqual([""]);
  });

  it("resets the input when snapshotting the pick fails", async () => {
    const element = document.createElement("div");
    document.body.append(element);

    editor = new Editor({
      element,
      extensions: [StarterKit, PublicFileEmbed],
      content: "<p>hello</p>",
    });

    const uploaded: File[] = [];

    render(
      <PublicFilesSettingsContext.Provider
        value={{
          files: [],
          onUpload: ({ file }) => {
            uploaded.push(file);
          },
        }}
      >
        <PublicFilePicker mountedEditor={editor} />
      </PublicFilesSettingsContext.Provider>,
    );

    const input = document.querySelector<HTMLInputElement>('input[type="file"]');
    if (!input) throw new Error("Public file input did not mount");

    const picked = new File(["audio-bytes"], "preview.mp3", { type: "audio/mpeg" });
    Object.defineProperty(picked, "arrayBuffer", { value: () => Promise.reject(new Error("read failed")) });
    const valueWrites = attachPickedFile(input, picked);

    await act(async () => {
      fireEvent.change(input);
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(alerts).toEqual([{ message: "read failed", level: "error" }]);
    expect(uploaded).toEqual([]);
    expect(valueWrites).toEqual([""]);
  });
});
