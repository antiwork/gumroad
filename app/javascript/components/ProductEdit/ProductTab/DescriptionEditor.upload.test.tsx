// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { assertDefined } from "$app/utils/assert";

import { DescriptionEditor, useImageUpload } from "$app/components/ProductEdit/ProductTab/DescriptionEditor";

const cdn = vi.hoisted(() => {
  const state: { release: (() => void)[]; fail: (() => void)[] } = { release: [], fail: [] };
  vi.stubGlobal("SSR", false);
  vi.stubGlobal("Routes", new Proxy({}, { get: (_, name: string) => () => `/${name}` }));
  const json = (body: unknown) =>
    new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
  vi.stubGlobal("fetch", (url: string) => {
    if (!url.includes("s3_utility_cdn_url_for_blob_path")) return Promise.resolve(json([]));
    return new Promise<Response>((resolve) => {
      state.release.push(() => resolve(json({ url: "https://cdn.example.com/image.png" })));
      state.fail.push(() => resolve(new Response("Unavailable", { status: 500 })));
    });
  });
  return state;
});

vi.mock("$app/utils/prepareImageForUpload", () => ({
  isLikelyImageFile: () => true,
  prepareImageForUpload: (file: File) => Promise.resolve(file),
  heicDecodingLikely: () => false,
}));

type UploadCallback = (error: Error | null, blob: { key: string }) => void;
const uploads = vi.hoisted((): { pending: UploadCallback[] } => ({ pending: [] }));
vi.mock("@rails/activestorage", () => ({
  DirectUpload: class {
    create(callback: UploadCallback) {
      uploads.pending.push(callback);
    }
  },
}));

const Editor = () => {
  const { isUploading, setImagesUploading } = useImageUpload();
  const [description, setDescription] = React.useState("");
  return (
    <>
      <DescriptionEditor
        id="product-1"
        initialDescription="<p>Description</p>"
        onChange={setDescription}
        publicFiles={[]}
        updatePublicFiles={() => {}}
        setImagesUploading={setImagesUploading}
      />
      <button disabled={isUploading}>Save changes</button>
      <output>{description}</output>
    </>
  );
};

beforeEach(() => {
  uploads.pending.length = 0;
  cdn.release.length = 0;
  cdn.fail.length = 0;
});

afterEach(cleanup);

const selectImages = (container: HTMLElement, count = 1) => {
  const input = assertDefined(container.querySelector<HTMLInputElement>('input[type="file"][accept*="png"]'));
  const picked = Array.from({ length: count }, (_, i) => new File(["pixels"], `photo-${i}.png`, { type: "image/png" }));
  Object.defineProperty(input, "files", {
    configurable: true,
    value: {
      length: picked.length,
      item: (index: number) => picked[index] ?? null,
      [Symbol.iterator]: () => picked[Symbol.iterator](),
    },
  });
  fireEvent.change(input);
};

const saveDisabled = () => screen.getByRole<HTMLButtonElement>("button", { name: "Save changes" }).disabled;

describe("description image uploads", () => {
  it("keeps the upload guard active while the editor still holds the local blob URL", async () => {
    const { container } = render(<Editor />);
    selectImages(container);
    await waitFor(() => expect(uploads.pending).toHaveLength(1));
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Save changes" }).disabled).toBe(true);

    assertDefined(uploads.pending.shift())(null, { key: "blob-key" });
    await waitFor(() => expect(cdn.release).toHaveLength(1));
    expect(container.querySelector("img")?.getAttribute("src")).toMatch(/^blob:/u);
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Save changes" }).disabled).toBe(true);

    cdn.release.forEach((release) => release());
    await waitFor(() =>
      expect(container.querySelector("img")?.getAttribute("src")).toBe("https://cdn.example.com/image.png"),
    );
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Save changes" }).disabled).toBe(false);
  });

  it("waits for every selected image's CDN lookup", async () => {
    const { container } = render(<Editor />);
    selectImages(container, 2);
    await waitFor(() => expect(uploads.pending).toHaveLength(2));
    uploads.pending.forEach((callback) => callback(null, { key: "blob-key" }));
    await waitFor(() => expect(cdn.release).toHaveLength(2));
    assertDefined(cdn.release[0])();
    await waitFor(() =>
      expect(container.querySelectorAll('img[src="https://cdn.example.com/image.png"]')).toHaveLength(1),
    );
    expect(container.querySelectorAll('img[src^="blob:"]')).toHaveLength(1);
    expect(saveDisabled()).toBe(true);
    assertDefined(cdn.release[1])();
    await waitFor(() =>
      expect(container.querySelectorAll('img[src="https://cdn.example.com/image.png"]')).toHaveLength(2),
    );
    expect(saveDisabled()).toBe(false);
  });

  it.each(["upload", "CDN lookup"])("releases the guard after a failed %s and permits retry", async (failure) => {
    const { container } = render(<Editor />);
    selectImages(container);
    await waitFor(() => expect(uploads.pending).toHaveLength(1));
    const uploaded = assertDefined(uploads.pending.shift());
    if (failure === "upload") uploaded(new Error("Upload failed"), { key: "unused" });
    else {
      uploaded(null, { key: "blob-key" });
      await waitFor(() => expect(cdn.fail).toHaveLength(1));
      assertDefined(cdn.fail[0])();
    }
    await waitFor(() => expect(saveDisabled()).toBe(false));
    await waitFor(() => expect(container.querySelector("img")).toBeNull());
    await waitFor(() => expect(container.querySelector<HTMLInputElement>('input[type="file"]')?.disabled).toBe(false));
    cdn.release.length = 0;
    selectImages(container);
    await waitFor(() => expect(uploads.pending).toHaveLength(1));
    expect(saveDisabled()).toBe(true);
    assertDefined(uploads.pending.shift())(null, { key: "retry-blob" });
    await waitFor(() => expect(cdn.release).toHaveLength(1));
    expect(saveDisabled()).toBe(true);
    assertDefined(cdn.release[0])();
    await waitFor(() =>
      expect(container.querySelector("img")?.getAttribute("src")).toBe("https://cdn.example.com/image.png"),
    );
    expect(saveDisabled()).toBe(false);
  });
});
