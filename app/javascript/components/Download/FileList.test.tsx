// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { FileItem, FileList, FolderItem, videoFrameStyle } from "$app/components/Download/FileList";

afterEach(cleanup);

const folder = (overrides: Partial<FolderItem> = {}): FolderItem => ({
  type: "folder",
  id: "folder-1",
  name: "GOYOW",
  children: [],
  ...overrides,
});

const videoFile = (overrides: Partial<FileItem> = {}): FileItem => ({
  type: "file",
  id: "file-1",
  file_name: "Welcome message",
  description: null,
  extension: "MOV",
  file_size: null,
  pagelength: null,
  duration: null,
  content_length: null,
  download_url: null,
  latest_media_location: null,
  stream_url: "/stream",
  external_link_url: null,
  kindle_data: null,
  read_url: null,
  pdf_stamp_enabled: false,
  processing: false,
  thumbnail_url: null,
  ...overrides,
});

describe("FileList", () => {
  it("renders folders collapsed by default when the page has multiple folders", () => {
    render(<FileList content_items={[folder(), folder({ id: "folder-2", name: "Extras" })]} />);

    expect(screen.getByRole("treeitem", { name: /GOYOW/u }).getAttribute("aria-expanded")).toBe("false");
    expect(screen.getByRole("treeitem", { name: /Extras/u }).getAttribute("aria-expanded")).toBe("false");
  });

  it("renders a folder expanded when the seller enabled expanded_by_default on it", () => {
    render(
      <FileList content_items={[folder({ expanded_by_default: true }), folder({ id: "folder-2", name: "Extras" })]} />,
    );

    expect(screen.getByRole("treeitem", { name: /GOYOW/u }).getAttribute("aria-expanded")).toBe("true");
    expect(screen.getByRole("treeitem", { name: /Extras/u }).getAttribute("aria-expanded")).toBe("false");
  });

  it("renders a single top-level folder expanded even without the per-folder setting", () => {
    render(<FileList content_items={[folder()]} />);

    expect(screen.getByRole("treeitem", { name: /GOYOW/u }).getAttribute("aria-expanded")).toBe("true");
  });

  it("still allows collapsing a folder that started expanded", () => {
    render(<FileList content_items={[folder({ expanded_by_default: true })]} />);

    fireEvent.click(screen.getByRole("heading", { name: "GOYOW" }));
    expect(screen.getByRole("treeitem", { name: /GOYOW/u }).getAttribute("aria-expanded")).toBe("false");
  });

  describe("videoFrameStyle", () => {
    it("shapes the player frame to a portrait video and caps its height so it fits the viewport", () => {
      const style = videoFrameStyle(videoFile({ width: 1080, height: 1920 }));

      expect(style?.aspectRatio).toBe("1080 / 1920");
      expect(style?.maxWidth).toBe("calc(80svh * 1080 / 1920)");
      expect(style?.marginInline).toBe("auto");
    });

    it("shapes the frame to a landscape video without capping its height", () => {
      const style = videoFrameStyle(videoFile({ width: 1920, height: 1080 }));

      expect(style?.aspectRatio).toBe("1920 / 1080");
      expect(style?.maxWidth).toBeUndefined();
    });

    it("leaves the frame alone when the video's dimensions are unknown or unusable", () => {
      expect(videoFrameStyle(videoFile())).toBeUndefined();
      expect(videoFrameStyle(videoFile({ width: 1080, height: null }))).toBeUndefined();
      expect(videoFrameStyle(videoFile({ width: 0, height: 0 }))).toBeUndefined();
    });
  });
});
