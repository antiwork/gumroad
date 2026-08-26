// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { EditorContent, useEditor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { FileEmbed, FileEmbedConfig } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { FileEntry } from "$app/components/ProductEdit/state";

// vite.config.ts replaces the bare `SSR` identifier at build time.
Object.assign(globalThis, { SSR: false });

const FILE_ID = "file-1";

const context = vi.hoisted(() => ({
  id: "product-id",
  updateProduct: (_update: unknown) => {},
  filesById: new Map<string, FileEntry>(),
}));

vi.mock("$app/components/ProductEdit/state", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/ProductEdit/state")>();
  return { ...mod, useProductEditContext: () => context };
});
const cancelUpload = vi.hoisted(() => vi.fn());
vi.mock("$app/components/EvaporateUploader", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/EvaporateUploader")>();
  return { ...mod, useEvaporateUploader: () => ({ scheduleUpload: () => 0, cancelUpload }) };
});
vi.mock("$app/components/S3UploadConfig", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/S3UploadConfig")>();
  return {
    ...mod,
    useS3UploadConfig: () => ({ generateS3KeyForUpload: () => ({ s3key: "key", fileUrl: "url" }) }),
  };
});
// Pin the row visible so the Cancel button isn't virtualized away.
vi.mock("$app/components/ProductEdit/ContentTab/useNodeVisibility", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/ProductEdit/ContentTab/useNodeVisibility")>();
  const react = await import("react");
  return {
    ...mod,
    useNodeVisibility: () => ({ ref: react.useRef(null), visible: true, lastHeight: { current: 82 } }),
  };
});

afterEach(() => {
  cleanup();
  cancelUpload.mockReset();
});

// eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- fixture only needs the fields the node view reads
const uploadingFile = {
  id: FILE_ID,
  display_name: "huge",
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
  status: {
    type: "unsaved",
    uploadStatus: { type: "uploading", progress: { percent: 0.1, bitrate: 0 } },
    url: "blob:huge",
  },
  thumbnail: null,
} as FileEntry;

const FileEmbedEditor = ({ config }: { config: FileEmbedConfig }) => {
  const editor = useEditor({
    extensions: [StarterKit, FileEmbed.configure({ getConfig: () => config })],
    content: { type: "doc", content: [{ type: "fileEmbed", attrs: { id: FILE_ID, uid: "uid-1" } }] },
    immediatelyRender: false,
  });
  return <EditorContent editor={editor} />;
};

it("tells the config which file was cancelled when the seller cancels an in-progress upload", async () => {
  const onUploadCancelled = vi.fn();
  const filesById = new Map<string, FileEntry>([[FILE_ID, uploadingFile]]);
  context.filesById = filesById;

  render(<FileEmbedEditor config={{ filesById, onUploadCancelled }} />);
  await act(() => Promise.resolve());

  act(() => {
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  });

  expect(cancelUpload).toHaveBeenCalledWith(`file_${FILE_ID}`);
  expect(onUploadCancelled).toHaveBeenCalledWith(FILE_ID);
});
