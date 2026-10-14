// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

import { trackMediaLocationChanged } from "$app/data/media_location";
import { assertDefined } from "$app/utils/assert";

import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { FileItem, FileList } from "$app/components/Download/FileList";
import { FilesAndFoldersDownloadInfoProvider, RichContentView } from "$app/components/Download/RichContent";
import {
  ContentFilesProvider,
  IsMobileAppViewProvider,
  MediaUrlsProvider,
  PurchaseInfoProvider,
} from "$app/components/DownloadPage/WithContent";
import { UserAgentProvider } from "$app/components/UserAgent";

vi.mock("$app/data/user_action_event", () => ({ trackUserActionEvent: vi.fn() }));
vi.mock("$app/data/consumption_analytics", () => ({ createConsumptionEvent: vi.fn() }));
vi.mock("$app/data/media_location", () => ({ trackMediaLocationChanged: vi.fn() }));

const play = vi.fn<(this: HTMLMediaElement) => Promise<void>>();

const audioFile = (id: string): FileItem => ({
  type: "file",
  id,
  file_name: id,
  description: null,
  extension: "MP3",
  file_size: 100,
  pagelength: null,
  duration: 120,
  content_length: 120,
  download_url: null,
  latest_media_location: null,
  stream_url: null,
  external_link_url: null,
  kindle_data: null,
  read_url: null,
  pdf_stamp_enabled: false,
  processing: false,
  thumbnail_url: null,
});

beforeEach(() => {
  vi.stubGlobal("SSR", false);
  play.mockImplementation(function (this: HTMLMediaElement) {
    Object.defineProperty(this, "paused", { configurable: true, value: false });
    return Promise.resolve();
  });
  vi.spyOn(HTMLMediaElement.prototype, "play").mockImplementation(play);
  vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(function (this: HTMLMediaElement) {
    Object.defineProperty(this, "paused", { configurable: true, value: true });
  });
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

const renderAudioFiles = (layout = "rich content") => {
  const files = [audioFile("first"), audioFile("second")];
  const embeddedFiles = layout === "duplicate" ? [assertDefined(files[0]), assertDefined(files[0])] : files;
  const urls = { first: ["https://example.com/first.mp3"], second: ["https://example.com/second.mp3"] };
  return render(
    <DomainSettingsProvider
      value={{
        scheme: "https",
        appDomain: "gumroad.com",
        rootDomain: "gumroad.com",
        shortDomain: "gum.co",
        discoverDomain: "gumroad.com",
        thirdPartyAnalyticsDomain: "example.com",
        apiDomain: "api.gumroad.com",
      }}
    >
      <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
        <PurchaseInfoProvider value={{ purchaseId: "purchase", redirectId: "redirect", token: "token" }}>
          <MediaUrlsProvider value={[urls, vi.fn()]}>
            <IsMobileAppViewProvider value={false}>
              <ContentFilesProvider value={files}>
                <FilesAndFoldersDownloadInfoProvider
                  value={{
                    downloadableFiles: [],
                    isMobileAppWebView: false,
                    pdfStampingEnabled: false,
                    getFolderArchive: vi.fn(),
                    getDownloadUrlsForFiles: vi.fn(),
                    hasStreamable: () => true,
                  }}
                >
                  {layout !== "file list" ? (
                    <RichContentView
                      richContent={{
                        type: "doc",
                        content: embeddedFiles.map((file, index) =>
                          layout === "folders"
                            ? {
                                type: "fileEmbedGroup",
                                attrs: { uid: `folder-${index}`, name: `Folder ${index}`, expandedByDefault: true },
                                content: [{ type: "fileEmbed", attrs: { id: file.id } }],
                              }
                            : { type: "fileEmbed", attrs: { id: file.id } },
                        ),
                      }}
                      saleInfo={null}
                      license={null}
                    />
                  ) : (
                    <FileList content_items={files} />
                  )}
                </FilesAndFoldersDownloadInfoProvider>
              </ContentFilesProvider>
            </IsMobileAppViewProvider>
          </MediaUrlsProvider>
        </PurchaseInfoProvider>
      </UserAgentProvider>
    </DomainSettingsProvider>,
  );
};

const audioAt = (index: number) => assertDefined(document.querySelectorAll("audio")[index]);
const loadAudio = async (audio: HTMLAudioElement) => {
  Object.defineProperty(audio, "duration", { configurable: true, value: 120 });
  await act(async () => {
    fireEvent.loadedMetadata(audio);
    await Promise.resolve();
  });
};

it.each(["file list", "rich content", "duplicate", "folders"])(
  "pauses the previous audio player when another starts in %s",
  async (layout) => {
    const view = renderAudioFiles(layout);
    const buttons = await screen.findAllByRole("button", { name: "Play Button" });
    fireEvent.click(assertDefined(buttons[0]));
    const firstAudio = audioAt(0);
    await loadAudio(firstAudio);
    expect(firstAudio.paused).toBe(false);

    fireEvent.click(assertDefined(buttons[1]));
    const secondAudio = audioAt(1);
    await loadAudio(secondAudio);
    expect(secondAudio.paused).toBe(false);
    expect(firstAudio.paused).toBe(true);
    secondAudio.currentTime = 20;
    fireEvent.timeUpdate(secondAudio);
    expect(trackMediaLocationChanged).toHaveBeenLastCalledWith(
      expect.objectContaining({ productFileId: layout === "duplicate" ? "first" : "second", location: 20 }),
    );

    fireEvent.click(within(assertDefined(firstAudio.parentElement)).getByRole("button", { name: "Play" }));
    await act(async () => {});
    expect(firstAudio.paused).toBe(false);
    expect(secondAudio.paused).toBe(true);

    fireEvent.click(assertDefined(buttons[1]));
    expect(firstAudio.paused).toBe(false);
    view.unmount();
    expect(firstAudio.paused).toBe(true);
  },
);

it("keeps a deselected player paused when its metadata arrives late", async () => {
  renderAudioFiles();
  const buttons = await screen.findAllByRole("button", { name: "Play Button" });
  fireEvent.click(assertDefined(buttons[0]));
  const firstAudio = audioAt(0);
  fireEvent.click(assertDefined(buttons[1]));
  const secondAudio = audioAt(1);
  await loadAudio(secondAudio);

  await loadAudio(firstAudio);

  expect(firstAudio.paused).toBe(true);
  expect(secondAudio.paused).toBe(false);
});

it("does not reselect a player when an earlier play promise resolves after it was paused", async () => {
  let finishFirstPlay: (() => void) | undefined;
  play.mockImplementation(function (this: HTMLMediaElement) {
    Object.defineProperty(this, "paused", { configurable: true, value: false });
    if (this.src.endsWith("first.mp3"))
      return new Promise<void>((resolve) => {
        finishFirstPlay = resolve;
      });
    return Promise.resolve();
  });
  renderAudioFiles();
  const buttons = await screen.findAllByRole("button", { name: "Play Button" });
  fireEvent.click(assertDefined(buttons[0]));
  fireEvent.click(assertDefined(buttons[1]));
  await loadAudio(audioAt(1));
  await act(async () => {
    assertDefined(finishFirstPlay)();
    await Promise.resolve();
  });

  expect(audioAt(0).paused).toBe(true);
  expect(audioAt(1).paused).toBe(false);
});

it("shows a playable control when the browser rejects the initial play request", async () => {
  play.mockRejectedValue(new Error("Playback requires user interaction"));
  renderAudioFiles();
  fireEvent.click(assertDefined((await screen.findAllByRole("button", { name: "Play Button" }))[0]));
  await loadAudio(audioAt(0));

  expect(screen.queryByRole("button", { name: "Pause" })).toBeNull();
  expect(screen.getByRole("button", { name: "Play" })).toBeDefined();
});
