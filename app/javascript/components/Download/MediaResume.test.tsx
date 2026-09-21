// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import Stream from "$app/pages/UrlRedirects/Stream";

import { FileItem, FileRow } from "$app/components/Download/FileList";
import { AudioPlayerContainer } from "$app/components/DownloadPage/AudioPlayerContainer";
import {
  IsMobileAppViewProvider,
  MediaUrlsProvider,
  PurchaseInfoProvider,
} from "$app/components/DownloadPage/WithContent";

const mocks = vi.hoisted(() => ({ request: vi.fn(), createJWPlayer: vi.fn(), usePage: vi.fn() }));
vi.mock("$app/utils/request", () => ({ request: mocks.request }));
vi.mock("$app/utils/jwPlayer", () => ({ createJWPlayer: mocks.createJWPlayer }));
vi.mock("@inertiajs/react", () => ({ usePage: mocks.usePage }));
vi.mock("$app/data/consumption_analytics", () => ({ createConsumptionEvent: vi.fn() }));
vi.mock("$app/data/user_action_event", () => ({ trackUserActionEvent: vi.fn() }));
vi.mock("$app/components/UserAgent", () => ({ useUserAgentInfo: () => ({ locale: "en-US" }) }));

const file: FileItem = {
  type: "file",
  id: "file-1",
  file_name: "Lecture",
  description: null,
  extension: "MP4",
  file_size: 1024,
  pagelength: null,
  duration: null,
  content_length: null,
  download_url: null,
  latest_media_location: null,
  stream_url: "https://example.com/stream",
  external_link_url: null,
  kindle_data: null,
  read_url: null,
  pdf_stamp_enabled: false,
  processing: false,
  thumbnail_url: null,
};
const wrap = (children: React.ReactNode) => (
  <IsMobileAppViewProvider value={false}>
    <PurchaseInfoProvider value={{ purchaseId: "purchase-1", redirectId: "redirect-1", token: "token" }}>
      <MediaUrlsProvider value={[{ "file-1": ["https://example.com/media"] }, vi.fn()]}>{children}</MediaUrlsProvider>
    </PurchaseInfoProvider>
  </IsMobileAppViewProvider>
);
const renderAudio = (saved: number, length: number | null = null) => {
  const view = render(
    wrap(
      <AudioPlayerContainer
        fileId="file-1"
        playingAudioForId="file-1"
        setPlayingAudioForId={vi.fn()}
        resumeLocation={saved}
        setResumeLocation={vi.fn()}
        contentLength={length}
      />,
    ),
  );
  const audio = view.container.querySelector("audio");
  if (!audio) throw new Error("Audio player did not mount");
  return { ...view, audio };
};
const loadAudio = async (audio: HTMLAudioElement, duration: number) => {
  Object.defineProperty(audio, "duration", { configurable: true, value: duration });
  await act(async () => fireEvent.loadedMetadata(audio));
};
const savedLocation = () => mocks.request.mock.lastCall?.[0].data.location;
const fakePlayer = (duration: number) => {
  const handlers = new Map<string, (event?: unknown) => void>();
  const player = {
    on: vi.fn((event: string, handler: (event?: unknown) => void) => {
      handlers.set(event, handler);
      return player;
    }),
    play: vi.fn(),
    seek: vi.fn(),
    remove: vi.fn(),
    playlistItem: vi.fn(),
    getPlaylistIndex: () => 0,
    getDuration: vi.fn(() => duration),
  };
  mocks.createJWPlayer.mockResolvedValue(player);
  return { player, emit: (event: string, payload?: unknown) => act(() => handlers.get(event)?.(payload)) };
};
const renderStream = (saved: number, length: number | null = null) => {
  mocks.usePage.mockReturnValue({
    props: {
      playlist: [
        {
          sources: ["https://example.com/video"],
          guid: "guid",
          title: "Lecture",
          tracks: [],
          external_id: "file-1",
          latest_media_location: { location: saved },
          content_length: length,
        },
      ],
      index_to_play: 0,
      url_redirect_id: "redirect-1",
      purchase_id: "purchase-1",
      should_show_transcoding_notice: false,
      transcode_on_first_sale: false,
    },
  });
  return render(<Stream />);
};
const renderEmbeddedRow = (saved: number, length: number | null = null) =>
  render(
    wrap(
      <FileRow
        file={{
          ...file,
          content_length: length,
          latest_media_location: { location: saved, timestamp: "2026-01-01T00:00:00Z" },
        }}
        playingAudioForId={null}
        setPlayingAudioForId={vi.fn()}
        isEmbed
      />,
    ),
  );
const boundaries: [number, number, number][] = [
  [600, 300, 300],
  [600, 590, 0],
  [600, 600, 0],
  [600, 610, 0],
  [10, 9.499, 9.499],
  [10, 9.5, 0],
  [10, 9.501, 0],
  [0, 120, 120],
];

beforeEach(() => {
  vi.useFakeTimers();
  vi.stubGlobal("Routes", { media_locations_path: () => "/media_locations.json" });
  mocks.request.mockResolvedValue({});
  vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue();
  vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => {});
});
afterEach(() => {
  cleanup();
  vi.clearAllTimers();
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.clearAllMocks();
  vi.unstubAllGlobals();
});

describe("saved media caller lifecycles", () => {
  it.each(boundaries)("audio restores %s seconds / saved %s to %s", async (duration, saved, expected) => {
    const { audio } = renderAudio(saved);
    await loadAudio(audio, duration);
    expect(audio.currentTime).toBe(expected);
  });

  it("preserves live audio through pause/resume and cancels a trailing save on completion", async () => {
    const { audio } = renderAudio(300);
    await loadAudio(audio, 600);
    audio.currentTime = 120;
    fireEvent.timeUpdate(audio);
    audio.currentTime = 580;
    fireEvent.timeUpdate(audio);
    fireEvent.click(screen.getByRole("button", { name: "Pause" }));
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Play" })));
    expect(audio.currentTime).toBe(580);
    fireEvent.ended(audio);
    expect(savedLocation()).toBe(600);
    act(() => vi.advanceTimersByTime(10000));
    expect(savedLocation()).toBe(600);
  });

  it.each([null, 0, -1])("does not replace progress with an unavailable completion duration %s", (length) => {
    const { audio } = renderAudio(0, length);
    audio.currentTime = 120;
    fireEvent.timeUpdate(audio);
    fireEvent.ended(audio);
    expect(savedLocation()).toBe(120);
  });

  it.each([
    [null, 600],
    [0, 580],
    [-1, 580],
  ])("audio saves through backend length %s without clamping progress to zero", async (length, expected) => {
    const { audio } = renderAudio(0, length);
    audio.currentTime = 120;
    fireEvent.timeUpdate(audio);
    expect(savedLocation()).toBe(120);
    await loadAudio(audio, 600);
    audio.currentTime = 580;
    fireEvent.timeUpdate(audio);
    act(() => vi.advanceTimersByTime(10000));
    expect(savedLocation()).toBe(expected);
    fireEvent.seeked(audio);
    expect(savedLocation()).toBe(expected);
    expect(mocks.request).toHaveBeenLastCalledWith(
      expect.objectContaining({
        method: "POST",
        data: expect.objectContaining({
          platform: "web",
          purchase_id: "purchase-1",
          product_file_id: "file-1",
          url_redirect_id: "redirect-1",
        }),
      }),
    );
  });

  it.each(boundaries)("embedded row restores %s seconds / saved %s to %s", async (duration, saved, expected) => {
    const { player, emit } = fakePlayer(duration);
    render(
      wrap(
        <FileRow
          file={{ ...file, latest_media_location: { location: saved, timestamp: "2026-01-01T00:00:00Z" } }}
          playingAudioForId={null}
          setPlayingAudioForId={vi.fn()}
          isEmbed
        />,
      ),
    );
    fireEvent.click(screen.getByRole("button", { name: /Watch|Resume/u }));
    await act(async () => {});
    emit("play");
    expect(player.seek).toHaveBeenCalledWith(expected);
    player.seek.mockClear();
    emit("pause");
    emit("play");
    expect(player.seek).not.toHaveBeenCalled();
  });

  it.each([300, 600])("reuses a mounted row with a newer native saved position of %s", async (location) => {
    const { player, emit } = fakePlayer(600);
    const row = (saved: number) =>
      wrap(
        <FileRow
          file={{ ...file, latest_media_location: { location: saved, timestamp: "2026-01-01T00:00:00Z" } }}
          playingAudioForId={null}
          setPlayingAudioForId={vi.fn()}
          isEmbed
        />,
      );
    const view = render(row(120));
    view.rerender(row(location));
    fireEvent.click(screen.getByRole("button", { name: /Watch|Resume/u }));
    await act(async () => {});
    emit("play");
    expect(player.seek).toHaveBeenCalledWith(location === 600 ? 0 : location);
  });

  it("embedded row saves through the web API and reopens the same file at the beginning", async () => {
    const first = fakePlayer(600);
    const view = render(wrap(<FileRow file={file} playingAudioForId={null} setPlayingAudioForId={vi.fn()} isEmbed />));
    fireEvent.click(screen.getByRole("button", { name: "Watch" }));
    await act(async () => {});
    first.emit("play");
    first.emit("time", { position: 120 });
    expect(savedLocation()).toBe(120);
    first.emit("time", { position: 580 });
    act(() => vi.advanceTimersByTime(10000));
    expect(savedLocation()).toBe(600);
    const saved = savedLocation();
    view.unmount();
    const reopened = fakePlayer(600);
    render(
      wrap(
        <FileRow
          file={{ ...file, latest_media_location: { location: saved, timestamp: "2026-01-01T00:00:00Z" } }}
          playingAudioForId={null}
          setPlayingAudioForId={vi.fn()}
          isEmbed
        />,
      ),
    );
    fireEvent.click(screen.getByRole("button", { name: /Watch|Resume/u }));
    await act(async () => {});
    reopened.emit("play");
    expect(reopened.player.seek).toHaveBeenCalledWith(0);
  });

  it.each(boundaries)("stream restores %s seconds / saved %s to %s", async (duration, saved, expected) => {
    const { player, emit } = fakePlayer(duration);
    renderStream(saved);
    await act(async () => {});
    emit("play");
    emit("visualQuality");
    if (expected) expect(player.seek).toHaveBeenCalledWith(expected);
    else expect(player.seek).not.toHaveBeenCalled();
    emit("time", { position: duration > 0 ? duration - 0.1 : 120, duration });
    expect(savedLocation()).toBe(duration > 0 ? duration : 120);
  });

  it.each([null, 0])(
    "embedded video keeps progress when the completion length is unavailable with content length %s",
    async (length) => {
      const { player, emit } = fakePlayer(0);
      renderEmbeddedRow(120, length);
      fireEvent.click(screen.getByRole("button", { name: /Watch|Resume/u }));
      await act(async () => {});
      emit("play");
      expect(player.seek).toHaveBeenCalledWith(120);
      emit("time", { position: 300 });
      expect(savedLocation()).toBe(300);
      emit("complete");
      expect(savedLocation()).toBe(300);
    },
  );

  it.each([null, 0])(
    "stream keeps progress when the completion length is unavailable with content length %s",
    async (length) => {
      const { player, emit } = fakePlayer(0);
      renderStream(120, length);
      await act(async () => {});
      emit("play");
      emit("visualQuality");
      expect(player.seek).toHaveBeenCalledWith(120);
      emit("time", { position: 300, duration: 0 });
      expect(savedLocation()).toBe(300);
      emit("complete");
      expect(savedLocation()).toBe(300);
    },
  );
});
