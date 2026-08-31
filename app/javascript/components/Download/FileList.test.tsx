// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { videoFrameIsPortrait, videoFrameStyle } from "$app/utils/videoFrame";

import { FileItem, FileList, FileRow, FolderItem } from "$app/components/Download/FileList";
import {
  IsMobileAppViewProvider,
  MediaUrlsProvider,
  PurchaseInfoProvider,
} from "$app/components/DownloadPage/WithContent";

// The component chains off createJWPlayer's promise and wires event handlers onto
// the player it resolves to, so the stub has to look enough like a player for that
// chain to complete. Every handler registration returns the player, as JW's does.
const createJWPlayer = vi.hoisted(() =>
  vi.fn((_containerId: string, _options: Record<string, unknown>) => {
    const player: Record<string, unknown> = {
      getDuration: () => 0,
      getPlaylistIndex: () => 0,
      play: () => undefined,
      seek: () => undefined,
    };
    player.on = () => player;
    return Promise.resolve(player);
  }),
);
vi.mock("$app/utils/jwPlayer", () => ({ createJWPlayer }));

// Clicking the play button fires a tracking request, which reaches for the Rails
// route helpers the real page defines globally. Stub the one route it needs so the
// click can be exercised without pulling in the routes bundle.
vi.mock("$app/data/user_action_event", () => ({ trackUserActionEvent: vi.fn() }));

afterEach(() => {
  cleanup();
  createJWPlayer.mockReset();
  delete window.ReactNativeWebView;
});

const mockReactNativeWebView = () => {
  const postMessage = vi.fn();
  window.ReactNativeWebView = { postMessage };
  return postMessage;
};

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

// Renders the embedded-video row the way the content page does, so the tests can
// check the frame the buyer actually gets rather than only the style helper.
const renderFileRow = (file: FileItem, mediaUrls: Record<string, string[]> = {}, isEmbed = false) =>
  render(
    <PurchaseInfoProvider value={{ purchaseId: "purchase-1", redirectId: "redirect-1", token: "token-1" }}>
      <MediaUrlsProvider value={[mediaUrls, () => undefined]}>
        <IsMobileAppViewProvider value={false}>
          <FileRow file={file} playingAudioForId={null} setPlayingAudioForId={() => undefined} isEmbed={isEmbed} />
        </IsMobileAppViewProvider>
      </MediaUrlsProvider>
    </PurchaseInfoProvider>,
  );

const renderEmbeddedRow = (file: FileItem, mediaUrls: Record<string, string[]> = {}) =>
  renderFileRow(file, mediaUrls, true);

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
      expect(style?.width).toBe("min(100%, calc(80svh * 1080 / 1920))");
      expect(style?.marginInline).toBe("auto");
    });

    it("shapes the frame to a landscape video without capping its height", () => {
      const style = videoFrameStyle(videoFile({ width: 1920, height: 1080 }));

      expect(style?.aspectRatio).toBe("1920 / 1080");
      expect(style?.width).toBeUndefined();
      expect(style?.marginInline).toBeUndefined();
    });

    it("leaves the frame alone when the video's dimensions are unknown or unusable", () => {
      expect(videoFrameStyle(videoFile())).toBeUndefined();
      expect(videoFrameStyle(videoFile({ width: 1080, height: null }))).toBeUndefined();
      expect(videoFrameStyle(videoFile({ width: 0, height: 0 }))).toBeUndefined();
    });

    // Only a portrait box is narrower than the 16:9 thumbnails are sized for, so
    // only it should letterbox the still. Landscape rows must keep cropping to
    // fill, or a seller thumbnail that doesn't match the video's ratio would
    // gain bands it doesn't have today.
    it("only letterboxes the still for a portrait video", () => {
      expect(videoFrameIsPortrait(videoFile({ width: 1080, height: 1920 }))).toBe(true);
      expect(videoFrameIsPortrait(videoFile({ width: 1920, height: 1080 }))).toBe(false);
      expect(videoFrameIsPortrait(videoFile({ width: 1080, height: 1080 }))).toBe(false);
      expect(videoFrameIsPortrait(videoFile())).toBe(false);
    });
  });

  describe("native app video clicks", () => {
    it("passes the saved position to the native stream player", () => {
      const postMessage = mockReactNativeWebView();
      const file = videoFile({
        duration: 1800,
        content_length: 1800,
        latest_media_location: { location: 1209, timestamp: "2026-08-29T18:56:02Z" },
      });

      renderFileRow(file);
      fireEvent.click(screen.getByRole("link", { name: "Watch" }));

      expect(JSON.parse(String(postMessage.mock.calls[0]?.[0]))).toMatchObject({
        type: "click",
        payload: { resourceId: file.id, resumeAt: "1209", contentLength: "1800" },
      });
    });

    it("passes the saved position to embedded-video native watch clicks", () => {
      const postMessage = mockReactNativeWebView();
      const file = videoFile({
        duration: 5400,
        content_length: 5400,
        latest_media_location: { location: 3476, timestamp: "2026-08-29T18:25:20Z" },
      });

      renderEmbeddedRow(file, { [file.id]: ["https://example.test/index.m3u8"] });
      fireEvent.click(screen.getByRole("button", { name: "Watch" }));

      expect(JSON.parse(String(postMessage.mock.calls[0]?.[0]))).toMatchObject({
        type: "click",
        payload: { resourceId: file.id, resumeAt: "3476", contentLength: "5400" },
      });
      expect(createJWPlayer).not.toHaveBeenCalled();
    });
  });

  describe("the embedded video frame", () => {
    it("shapes the pre-play frame to a portrait video's own ratio", () => {
      const { container } = renderEmbeddedRow(videoFile({ width: 1080, height: 1920 }));
      const frame = container.querySelector<HTMLElement>(".preview");

      expect(frame?.style.aspectRatio).toBe("1080 / 1920");
      expect(frame?.style.marginInline).toBe("auto");
    });

    it("leaves the pre-play frame unstyled for a video with no recorded dimensions", () => {
      const { container } = renderEmbeddedRow(videoFile());
      const frame = container.querySelector<HTMLElement>(".preview");

      expect(frame).not.toBeNull();
      expect(frame?.style.aspectRatio).toBe("");
      expect(frame?.style.width).toBe("");
    });

    it("tells the player the video's real ratio, and shapes the playing frame to match", async () => {
      const file = videoFile({ width: 1080, height: 1920 });
      const { container } = renderEmbeddedRow(file, { [file.id]: ["https://example.test/index.m3u8"] });

      fireEvent.click(screen.getByRole("button", { name: "Watch" }));

      await waitFor(() => expect(createJWPlayer).toHaveBeenCalled());
      expect(createJWPlayer.mock.calls[0]?.[1]).toMatchObject({ aspectratio: "1080:1920" });
      expect(container.querySelector<HTMLElement>(".preview")?.style.aspectRatio).toBe("1080 / 1920");
    });

    it("does not send the player a ratio for a video with no recorded dimensions", async () => {
      const file = videoFile();
      renderEmbeddedRow(file, { [file.id]: ["https://example.test/index.m3u8"] });

      fireEvent.click(screen.getByRole("button", { name: "Watch" }));

      await waitFor(() => expect(createJWPlayer).toHaveBeenCalled());
      expect(createJWPlayer.mock.calls[0]?.[1]).not.toHaveProperty("aspectratio");
    });
  });
});
