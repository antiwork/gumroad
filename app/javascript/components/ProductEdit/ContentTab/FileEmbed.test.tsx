// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { type Editor, EditorContent, useEditor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { PICKED_FILE_SNAPSHOT_LIMIT_BYTES } from "$app/utils/snapshotPickedFile";

import { FileEmbed, FileEmbedConfig } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { FileEntry } from "$app/components/ProductEdit/state";

vi.mock("@rails/activestorage", () => ({
  DirectUpload: class {
    create(callback: (error: Error | null, blob: { key: string; signed_id: string }) => void) {
      callback(null, { key: "thumb-key", signed_id: "thumb-signed-id" });
    }
  },
}));

const alerts = vi.hoisted((): { message: string; level: string }[] => []);
vi.mock("$app/components/server-components/Alert", () => ({
  showAlert: (message: string, level: string) => alerts.push({ message, level }),
}));

// vite.config.ts replaces the bare `SSR` identifier at build time.
Object.assign(globalThis, { SSR: false });
// Rails injects this global; a `saved` file's download URL goes through it.
Object.assign(globalThis, {
  Routes: {
    download_product_files_path: (productId: string, options: { product_file_ids: string[] }) =>
      `/products/${productId}/download?product_file_ids=${options.product_file_ids.join(",")}`,
  },
});

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
const scheduledUploads = vi.hoisted((): { onComplete: () => void; onError?: () => void }[] => []);
vi.mock("$app/components/EvaporateUploader", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/EvaporateUploader")>();
  return {
    ...mod,
    useEvaporateUploader: () => ({
      scheduleUpload: (options: { onComplete: () => void; onError?: () => void }) => {
        scheduledUploads.push(options);
        return 0;
      },
      cancelUpload,
    }),
  };
});
vi.mock("$app/components/S3UploadConfig", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/S3UploadConfig")>();
  return {
    ...mod,
    useS3UploadConfig: () => ({
      generateS3KeyForUpload: (guid: string, name: string) => ({
        s3key: `key-${guid}`,
        fileUrl: `https://s3.example/${guid}/${name}`,
      }),
    }),
  };
});
// Pin the row visible so Cancel and the subtitle drawer aren't virtualized away.
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
  scheduledUploads.length = 0;
  alerts.length = 0;
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

// eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- fixture only needs the fields the node view reads
const failedFile = {
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
  status: { type: "unsaved", uploadStatus: { type: "failed" }, url: "blob:huge" },
  thumbnail: null,
} as FileEntry;

// eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- fixture only needs the fields the node view reads
const streamableFile = {
  id: FILE_ID,
  display_name: "video",
  description: null,
  extension: "MP4",
  file_size: 1024,
  is_pdf: false,
  pdf_stamp_enabled: false,
  hide_kindle_and_read_buttons: false,
  is_streamable: true,
  stream_only: false,
  is_transcoding_in_progress: false,
  url: "https://example.com/video.mp4",
  subtitle_files: [],
  status: { type: "unsaved", uploadStatus: { type: "uploaded" }, url: "blob:video" },
  thumbnail: null,
} as FileEntry;

const FileEmbedEditor = ({ config, onEditor }: { config: FileEmbedConfig; onEditor?: (editor: Editor) => void }) => {
  const editor = useEditor({
    extensions: [StarterKit, FileEmbed.configure({ getConfig: () => config })],
    content: { type: "doc", content: [{ type: "fileEmbed", attrs: { id: FILE_ID, uid: "uid-1" } }] },
    immediatelyRender: false,
  });
  React.useEffect(() => {
    if (editor) onEditor?.(editor);
  }, [editor]);
  return <EditorContent editor={editor} />;
};

const attachPickedFiles = (input: HTMLInputElement, picked: File[]) => {
  Object.defineProperty(input, "files", {
    configurable: true,
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- minimal FileList for the handler
    value: {
      ...picked,
      length: picked.length,
      item: (index: number) => picked[index] ?? null,
      [Symbol.iterator]: () => picked[Symbol.iterator](),
    } as unknown as FileList,
  });
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

it("shows a failed upload on the row, with no download, and removes it on Remove", async () => {
  const onUploadCancelled = vi.fn();
  const filesById = new Map<string, FileEntry>([[FILE_ID, failedFile]]);
  context.filesById = filesById;

  render(<FileEmbedEditor config={{ filesById, onUploadCancelled }} />);
  await act(() => Promise.resolve());

  expect(screen.getByText("Upload failed")).toBeTruthy();
  // Nothing landed in S3, so there is nothing to download and nothing to cancel.
  expect(screen.queryByText("Download")).toBeNull();
  expect(screen.queryByRole("button", { name: "Cancel" })).toBeNull();

  // Everything but Remove would edit a file the save discards, so the row offers nothing else.
  expect(screen.queryByRole("button", { name: "Edit" })).toBeNull();
  expect(screen.queryByRole("button", { name: "Thumbnail view" })).toBeNull();
  expect(screen.queryByRole("button", { name: "Play" })).toBeNull();

  act(() => {
    fireEvent.click(screen.getByRole("button", { name: "Remove" }));
  });

  expect(cancelUpload).toHaveBeenCalledWith(`file_${FILE_ID}`);
  expect(onUploadCancelled).toHaveBeenCalledWith(FILE_ID);
});

it("offers no closed-captions editor on a failed video row", async () => {
  const failedVideo: FileEntry = { ...failedFile, extension: "MP4", is_streamable: true };
  const filesById = new Map<string, FileEntry>([[FILE_ID, failedVideo]]);
  context.filesById = filesById;

  render(<FileEmbedEditor config={{ filesById }} />);
  await act(() => Promise.resolve());

  expect(screen.getByText("Upload failed")).toBeTruthy();
  expect(screen.queryByText(/closed caption/u)).toBeNull();
});

it("closes an open drawer when the upload fails, since its edits would not be saved", async () => {
  let editor: Editor | null = null;
  context.filesById = new Map<string, FileEntry>([[FILE_ID, uploadingFile]]);

  render(<FileEmbedEditor config={{ filesById: context.filesById }} onEditor={(value) => (editor = value)} />);
  await act(() => Promise.resolve());
  act(() => {
    fireEvent.click(screen.getByRole("button", { name: "Edit" }));
  });
  expect(screen.getByLabelText("Name")).toBeTruthy();

  context.filesById = new Map<string, FileEntry>([[FILE_ID, failedFile]]);
  // An attribute change re-renders the node view against the new files map.
  act(() => {
    editor?.commands.updateAttributes(FileEmbed.name, { uid: "uid-2" });
  });

  expect(screen.getByText("Upload failed")).toBeTruthy();
  expect(screen.queryByLabelText("Name")).toBeNull();

  // It stays closed once "Upload again" restarts the upload.
  context.filesById = new Map<string, FileEntry>([[FILE_ID, uploadingFile]]);
  act(() => {
    editor?.commands.updateAttributes(FileEmbed.name, { uid: "uid-3" });
  });
  expect(screen.queryByText("Upload failed")).toBeNull();
  expect(screen.queryByLabelText("Name")).toBeNull();
});

it("hands the Upload again pick to the config", async () => {
  const onRetryUpload = vi.fn();
  const filesById = new Map<string, FileEntry>([[FILE_ID, failedFile]]);
  context.filesById = filesById;
  const picked = new File(["x"], "huge.zip", { type: "application/zip" });
  render(<FileEmbedEditor config={{ filesById, onRetryUpload }} />);
  await act(() => Promise.resolve());
  const input = document.querySelector<HTMLInputElement>('input[type="file"]');
  if (!input) throw new Error("Upload again has no file input");
  const openPicker = vi.spyOn(input, "click").mockImplementation(() => {});

  act(() => {
    fireEvent.click(screen.getByRole("button", { name: "Upload again" }));
  });
  expect(openPicker).toHaveBeenCalled();

  attachPickedFiles(input, [picked]);
  act(() => {
    fireEvent.change(input);
  });

  expect(onRetryUpload).toHaveBeenCalledWith(FILE_ID, input);
});

it("attaches a generated thumbnail to a saved video", async () => {
  const file: FileEntry = { ...streamableFile, status: { type: "saved" }, thumbnail: null };
  const product: { files: FileEntry[] } = { files: [file] };
  context.filesById = new Map<string, FileEntry>([[FILE_ID, file]]);
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- fixture mapper matches updateProduct
    if (typeof update === "function") (update as (p: typeof product) => void)(product);
  };
  Object.assign(Routes, {
    rails_direct_uploads_path: () => "/rails/active_storage/direct_uploads",
    s3_utility_cdn_url_for_blob_path: ({ key }: { key: string }) => `/cdn/${key}`,
  });
  // happy-dom cannot decode video or draw to a canvas, so stand in for both.
  let video: HTMLVideoElement | null = null;
  const createElement = document.createElement.bind(document);
  const createElementSpy = vi.spyOn(document, "createElement").mockImplementation((tagName: string) => {
    if (tagName === "canvas")
      // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- only the calls generateThumbnail makes
      return {
        getContext: () => ({ drawImage: () => {} }),
        toBlob: (callback: (blob: Blob) => void) => callback(new Blob(["frame"])),
        remove: () => {},
      } as unknown as HTMLCanvasElement;
    const element = createElement(tagName);
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowed by the tag name
    if (tagName === "video") video = element as HTMLVideoElement;
    return element;
  });

  render(<FileEmbedEditor config={{ filesById: context.filesById }} />);
  await act(() => Promise.resolve());
  act(() => {
    fireEvent.click(screen.getByRole("button", { name: "Generate a thumbnail" }));
  });
  act(() => {
    video?.onseeked?.(new Event("seeked"));
  });
  createElementSpy.mockRestore();

  expect(product.files[0]?.thumbnail).toMatchObject({ url: "/cdn/thumb-key", signed_id: "thumb-signed-id" });
});

it("still offers the download for a file that finished uploading", async () => {
  const filesById = new Map<string, FileEntry>([[FILE_ID, streamableFile]]);
  context.filesById = filesById;

  render(<FileEmbedEditor config={{ filesById }} />);
  await act(() => Promise.resolve());

  expect(screen.getByText("Download")).toBeTruthy();
  expect(screen.queryByText("Upload failed")).toBeNull();
});

it("keeps every subtitle from a multi-file pick instead of last-write-wins", async () => {
  const file: FileEntry = { ...streamableFile, subtitle_files: [] };
  const product: { files: FileEntry[] } = { files: [file] };
  context.filesById = new Map<string, FileEntry>([[FILE_ID, file]]);
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- fixture mapper matches updateProduct
    if (typeof update === "function") (update as (p: typeof product) => void)(product);
  };

  render(<FileEmbedEditor config={{ filesById: context.filesById }} />);
  await act(() => Promise.resolve());

  act(() => {
    fireEvent.click(screen.getByRole("button", { name: "Edit" }));
  });

  const input = document.querySelector<HTMLInputElement>("input.subtitles-file");
  if (!input) throw new Error("Subtitle file input did not mount");
  attachPickedFiles(input, [
    new File(["en"], "english.srt", { type: "text/plain" }),
    new File(["es"], "spanish.srt", { type: "text/plain" }),
  ]);

  await act(async () => {
    fireEvent.change(input);
    // snapshotPickedFiles settles on a microtask after the change handler returns
    await Promise.resolve();
  });

  const names = product.files[0]?.subtitle_files.map((subtitle) => subtitle.file_name);
  // Both entries must land. Spreading the render-closed file.subtitle_files would
  // write [english] then overwrite with [spanish].
  expect(names).toEqual(["english", "spanish"]);
});

it("re-enables the subtitle picker when an over-budget upload errors", async () => {
  const file: FileEntry = { ...streamableFile, subtitle_files: [] };
  const product: { files: FileEntry[] } = { files: [file] };
  context.filesById = new Map<string, FileEntry>([[FILE_ID, file]]);
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- fixture mapper matches updateProduct
    if (typeof update === "function") (update as (p: typeof product) => void)(product);
  };

  render(<FileEmbedEditor config={{ filesById: context.filesById }} />);
  await act(() => Promise.resolve());

  act(() => {
    fireEvent.click(screen.getByRole("button", { name: "Edit" }));
  });

  const input = document.querySelector<HTMLInputElement>("input.subtitles-file");
  if (!input) throw new Error("Subtitle file input did not mount");
  const picked = new File(["x"], "huge.srt", { type: "text/plain" });
  Object.defineProperty(picked, "size", { value: PICKED_FILE_SNAPSHOT_LIMIT_BYTES + 1 });
  attachPickedFiles(input, [picked]);

  await act(async () => {
    fireEvent.change(input);
    await Promise.resolve();
  });

  expect(input.disabled).toBe(true);
  expect(scheduledUploads).toHaveLength(1);
  expect(product.files[0]?.subtitle_files).toHaveLength(1);

  await act(async () => {
    scheduledUploads[0]?.onError?.();
    await Promise.resolve();
  });

  expect(input.disabled).toBe(false);
  expect(product.files[0]?.subtitle_files).toEqual([]);
  expect(alerts).toEqual([{ message: "Subtitle upload failed.", level: "error" }]);
  expect(cancelUpload).toHaveBeenCalled();
});

it("renders no size for a file the server has not measured yet", async () => {
  // ProductFile#size is null until AnalyzeFileWorker measures it (gumroad-private#2584).
  const file: FileEntry = { ...streamableFile, file_size: null, status: { type: "saved" } };
  context.filesById = new Map<string, FileEntry>([[FILE_ID, file]]);

  render(<FileEmbedEditor config={{ filesById: context.filesById }} />);
  await act(() => Promise.resolve());

  expect(screen.getByText("MP4")).toBeTruthy();
  expect(screen.queryByText("0 byte")).toBeNull();
});

it("renders the human-readable size once the file has one", async () => {
  const file: FileEntry = { ...streamableFile, file_size: 1_746_035, status: { type: "saved" } };
  context.filesById = new Map<string, FileEntry>([[FILE_ID, file]]);

  render(<FileEmbedEditor config={{ filesById: context.filesById }} />);
  await act(() => Promise.resolve());

  expect(screen.getByText("1.7 MB")).toBeTruthy();
});

const documentFile: FileEntry = {
  ...streamableFile,
  display_name: "report",
  extension: "PDF",
  is_pdf: true,
  is_streamable: false,
  url: "https://example.com/report.pdf",
};

it("offers download-disabling on a document, with copy for the reader rather than streaming", async () => {
  const file: FileEntry = { ...documentFile, stream_only: true, status: { type: "saved" } };
  context.filesById = new Map<string, FileEntry>([[FILE_ID, file]]);

  render(<FileEmbedEditor config={{ filesById: context.filesById }} />);
  await act(() => Promise.resolve());

  act(() => {
    fireEvent.click(screen.getByRole("button", { name: "Edit" }));
  });

  expect(screen.getByText(/buyers read it in the browser instead/u)).toBeTruthy();
  expect(screen.queryByText(/stream only/u)).toBeNull();
  // The reader is the only way to open a document whose downloads are disabled.
  expect(screen.getByText(/stay on while downloads are disabled/u)).toBeTruthy();
});

it("offers no download switch for a file with no other way to open it", async () => {
  const file: FileEntry = {
    ...streamableFile,
    extension: "ZIP",
    is_streamable: false,
    status: { type: "saved" },
  };
  context.filesById = new Map<string, FileEntry>([[FILE_ID, file]]);

  render(<FileEmbedEditor config={{ filesById: context.filesById }} />);
  await act(() => Promise.resolve());

  act(() => {
    fireEvent.click(screen.getByRole("button", { name: "Edit" }));
  });

  expect(screen.queryByText(/Disable file downloads/u)).toBeNull();
});

const oversizedEpub: FileEntry = {
  ...documentFile,
  extension: "EPUB",
  is_pdf: false,
  file_size: 40 * 1024 * 1024,
};

it("shows the download switch off and says why when the server says the file is not eligible", async () => {
  const file: FileEntry = {
    ...oversizedEpub,
    can_disable_downloads: false,
    status: { type: "saved" },
  };
  context.filesById = new Map<string, FileEntry>([[FILE_ID, file]]);

  render(<FileEmbedEditor config={{ filesById: context.filesById }} />);
  await act(() => Promise.resolve());

  act(() => {
    fireEvent.click(screen.getByRole("button", { name: "Edit" }));
  });

  const downloadSwitch = screen.getByRole<HTMLInputElement>("switch", {
    name: /^Disable file downloads$/u,
  });
  expect(downloadSwitch.disabled).toBe(true);
  // The reason is what the switch is for, so it must stay outside the dimmed control's label.
  const reason = screen.getByText("This file is too large for the in-browser reader");
  expect(downloadSwitch.closest("label")?.contains(reason)).toBe(false);
  expect(downloadSwitch.getAttribute("aria-describedby")).toBe(reason.id);
  expect(screen.queryByText(/buyers read it in the browser instead/u)).toBeNull();
});

it("shows the same switch off for an oversized EPUB picked but not yet saved", async () => {
  // Unsaved files carry no server answer, so the editor has to apply the reader's size limit itself.
  context.filesById = new Map<string, FileEntry>([[FILE_ID, oversizedEpub]]);

  render(<FileEmbedEditor config={{ filesById: context.filesById }} />);
  await act(() => Promise.resolve());

  act(() => {
    fireEvent.click(screen.getByRole("button", { name: "Edit" }));
  });

  const downloadSwitch = screen.getByRole<HTMLInputElement>("switch", {
    name: /^Disable file downloads$/u,
  });
  expect(downloadSwitch.disabled).toBe(true);
  expect(screen.getByText("This file is too large for the in-browser reader")).toBeTruthy();
});
