// @vitest-environment happy-dom
import { describe, expect, it } from "vitest";

import { resolveCopiedFileEmbeds } from "$app/components/ProductEdit/ContentTab/resolveCopiedFileEmbeds";
import { ExistingFileEntry, FileEntry } from "$app/components/ProductEdit/state";

const buildFile = (id: string, url: string | null): FileEntry => ({
  display_name: `File ${id}`,
  description: null,
  extension: "PDF",
  file_size: 1024,
  is_pdf: true,
  pdf_stamp_enabled: false,
  hide_kindle_and_read_buttons: false,
  is_streamable: false,
  stream_only: false,
  is_transcoding_in_progress: false,
  id,
  url,
  subtitle_files: [],
  status: { type: "saved" },
  thumbnail: null,
});

const buildExistingFile = (id: string, url: string | null): ExistingFileEntry => ({
  ...buildFile(id, url),
  attached_product_name: null,
});

const buildFragment = (embeds: { id?: string; url?: string }[]) => {
  const fragment = document.createDocumentFragment();
  for (const attrs of embeds) {
    const node = document.createElement("file-embed");
    if (attrs.id != null) node.setAttribute("id", attrs.id);
    if (attrs.url != null) node.setAttribute("url", attrs.url);
    fragment.appendChild(node);
  }
  return fragment;
};

describe("resolveCopiedFileEmbeds", () => {
  it("keeps a dragged embed whose file already belongs to the product, stripping the url marker", () => {
    // Dragging a file embed to reorder it runs ProseMirror's copy serialization, which tags the
    // node with a `url` attribute even though it never left this product's editor.
    const file = buildFile("local-1", "blob:local");
    const fragment = buildFragment([{ id: "local-1", url: "blob:local" }]);

    const newFiles = resolveCopiedFileEmbeds(fragment, new Map([["local-1", file]]), []);

    const embed = fragment.querySelector("file-embed");
    expect(embed).not.toBeNull();
    expect(embed?.getAttribute("id")).toBe("local-1");
    expect(embed?.hasAttribute("url")).toBe(false);
    expect(newFiles).toEqual([]);
  });

  it("does not remove a freshly uploaded file that is missing from the existingFiles snapshot", () => {
    // existingFiles is a limited snapshot fetched at page load; files uploaded during the current
    // session are only present in filesById. They must never be dropped (gumroad-private#1164).
    const uploaded = buildFile("new-upload", "blob:new");
    const fragment = buildFragment([{ id: "new-upload", url: "blob:new" }]);

    resolveCopiedFileEmbeds(fragment, new Map([["new-upload", uploaded]]), [
      buildExistingFile("other", "https://s3/other"),
    ]);

    expect(fragment.querySelector("file-embed")).not.toBeNull();
  });

  it("maps an embed pasted from another product onto the matching existing file", () => {
    const existing = buildExistingFile("existing-1", "https://s3/existing-1");
    const fragment = buildFragment([{ id: "foreign-id", url: "https://s3/existing-1" }]);

    const newFiles = resolveCopiedFileEmbeds(fragment, new Map(), [existing]);

    const embed = fragment.querySelector("file-embed");
    expect(embed?.getAttribute("id")).toBe("existing-1");
    expect(embed?.hasAttribute("url")).toBe(false);
    expect(newFiles).toEqual([existing]);
  });

  it("removes an embed that matches neither the product's files nor the existing files", () => {
    const fragment = buildFragment([{ id: "unknown", url: "https://s3/unknown" }]);

    const newFiles = resolveCopiedFileEmbeds(fragment, new Map(), []);

    expect(fragment.querySelector("file-embed")).toBeNull();
    expect(newFiles).toEqual([]);
  });

  it("leaves embeds without a url attribute untouched", () => {
    const fragment = buildFragment([{ id: "plain" }]);

    resolveCopiedFileEmbeds(fragment, new Map(), []);

    const embed = fragment.querySelector("file-embed");
    expect(embed?.getAttribute("id")).toBe("plain");
  });

  it("returns each pasted file only once even when embedded multiple times", () => {
    const existing = buildExistingFile("existing-1", "https://s3/existing-1");
    const fragment = buildFragment([
      { id: "a", url: "https://s3/existing-1" },
      { id: "b", url: "https://s3/existing-1" },
    ]);

    const newFiles = resolveCopiedFileEmbeds(fragment, new Map(), [existing]);

    expect(newFiles).toEqual([existing]);
  });
});
