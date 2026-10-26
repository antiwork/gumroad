// @vitest-environment happy-dom
import { cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

import { ThumbnailEditor } from "$app/components/ProductEdit/ProductTab/ThumbnailEditor";
import { showAlert } from "$app/components/server-components/Alert";

type UploadCallback = (error: unknown, blob?: { signed_id: string }) => void;
const uploads = vi.hoisted((): { callbacks: UploadCallback[] } => ({ callbacks: [] }));

vi.mock("@rails/activestorage", () => ({
  DirectUpload: class {
    create(callback: UploadCallback) {
      uploads.callbacks.push(callback);
    }
  },
}));

vi.mock("$app/utils/prepareImageForUpload", () => ({
  isLikelyImageFile: () => true,
  prepareImageForUpload: (file: File) => Promise.resolve(file),
  heicDecodingLikely: () => false,
}));

vi.mock("$app/utils/image", () => ({
  getImageDimensionsFromFile: () => Promise.resolve({ height: 600, width: 600 }),
}));

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const thumbnails = vi.hoisted(() => ({ createThumbnail: vi.fn(), deleteThumbnail: vi.fn() }));
vi.mock("$app/data/thumbnails", () => thumbnails);

const FAILURE = 'Error storing "thumb.png". Status: 0';
const THUMBNAIL = { guid: "thumb-1", url: "https://cdn.example.com/thumb.png" };

const renderEditor = () => {
  const setThumbnail = vi.fn();
  const { container } = render(
    <ThumbnailEditor covers={[]} thumbnail={null} setThumbnail={setThumbnail} permalink="abc" nativeType="digital" />,
  );
  return { container, setThumbnail };
};

// The picker's `value` is reset after every change so the same file can be chosen again; happy-dom
// needs the setter defined for that write to land anywhere.
const selectFile = (container: HTMLElement) => {
  const input = container.querySelector('input[type="file"]');
  if (!(input instanceof HTMLInputElement)) throw new Error("Expected a file input");
  let pickerValue = "C:\\fakepath\\thumb.png";
  Object.defineProperty(input, "value", {
    configurable: true,
    get: () => pickerValue,
    set: (value: string) => {
      pickerValue = value;
    },
  });
  Object.defineProperty(input, "files", {
    configurable: true,
    value: [new File(["pixels"], "thumb.png", { type: "image/png" })],
  });
  fireEvent.change(input);
};

beforeEach(() => {
  uploads.callbacks.length = 0;
  thumbnails.createThumbnail.mockResolvedValue(THUMBNAIL);
});

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

it("retries a failed direct upload once and keeps the file", async () => {
  const { container, setThumbnail } = renderEditor();
  selectFile(container);

  await waitFor(() => expect(uploads.callbacks).toHaveLength(1));
  uploads.callbacks[0]?.(FAILURE);

  await waitFor(() => expect(uploads.callbacks).toHaveLength(2));
  expect(showAlert).not.toHaveBeenCalled();

  uploads.callbacks[1]?.(null, { signed_id: "signed-1" });

  await waitFor(() => expect(setThumbnail).toHaveBeenCalledWith(THUMBNAIL));
  expect(thumbnails.createThumbnail).toHaveBeenCalledWith("abc", { type: "file", signedBlobId: "signed-1" });
  expect(showAlert).not.toHaveBeenCalled();
});

it("shows the real upload failure instead of a blank alert once every attempt failed", async () => {
  const { container, setThumbnail } = renderEditor();
  selectFile(container);

  await waitFor(() => expect(uploads.callbacks).toHaveLength(1));
  uploads.callbacks[0]?.(FAILURE);

  await waitFor(() => expect(uploads.callbacks).toHaveLength(2));
  uploads.callbacks[1]?.(FAILURE);

  // DirectUpload calls back with a plain string, so `error.message` used to render as `undefined`.
  await waitFor(() => expect(showAlert).toHaveBeenCalledWith(FAILURE, "error"));
  expect(setThumbnail).not.toHaveBeenCalled();
  expect(thumbnails.createThumbnail).not.toHaveBeenCalled();
});
