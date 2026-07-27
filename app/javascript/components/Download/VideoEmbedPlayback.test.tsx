// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { isMediaPlaybackEvent, MEDIA_PLAYBACK_EVENT, MediaPlaybackEventDetail } from "$app/utils/media_playback";

import { FileItem, FileRow } from "$app/components/Download/FileList";
import {
  IsMobileAppViewProvider,
  MediaUrlsProvider,
  PurchaseInfoProvider,
} from "$app/components/DownloadPage/WithContent";

const mocks = vi.hoisted(() => ({ createJWPlayer: vi.fn() }));

vi.mock("$app/utils/jwPlayer", () => ({ createJWPlayer: mocks.createJWPlayer }));
// The embed reports view/position analytics as soon as it plays; those calls need a server and a
// Routes global that this test doesn't have, and none of them are what's under test here.
vi.mock("$app/data/consumption_analytics", () => ({ createConsumptionEvent: vi.fn() }));
vi.mock("$app/data/media_location", () => ({ trackMediaLocationChanged: vi.fn() }));
vi.mock("$app/data/user_action_event", () => ({ trackUserActionEvent: vi.fn() }));

const FILE_ID = "file-1";
const PLAYER_ID = `jwplayer-${FILE_ID}`;

const videoFile: FileItem = {
  type: "file",
  id: FILE_ID,
  file_name: "Lecture 1",
  description: null,
  extension: "MP4",
  file_size: 1024,
  pagelength: null,
  duration: 5400,
  content_length: 5400,
  download_url: null,
  latest_media_location: null,
  // A non-null stream_url is what makes the row render the embedded player.
  stream_url: "https://gumroad.example/stream",
  external_link_url: null,
  kindle_data: null,
  read_url: null,
  pdf_stamp_enabled: false,
  processing: false,
  thumbnail_url: null,
};

// A player object that records the events the component subscribes to, so a test can tell whether
// the component wired itself up to a player at all.
const fakePlayer = () => {
  const handlers = new Map<string, (event?: unknown) => void>();
  const player = {
    on: vi.fn((event: string, handler: (event?: unknown) => void) => {
      handlers.set(event, handler);
      return player;
    }),
    play: vi.fn(),
    getDuration: vi.fn(() => 5400),
    seek: vi.fn(),
  };
  return { player, handlers };
};

const renderEmbeddedVideoRow = () =>
  render(
    <IsMobileAppViewProvider value={false}>
      <PurchaseInfoProvider value={{ purchaseId: "purchase-1", redirectId: "redirect-1", token: "token" }}>
        {/* Pre-seeded media URLs so showing the player doesn't have to fetch them from the server. */}
        <MediaUrlsProvider value={[{ [FILE_ID]: ["https://gumroad.example/video.mp4"] }, vi.fn()]}>
          <FileRow file={videoFile} playingAudioForId={null} setPlayingAudioForId={vi.fn()} isEmbed />
        </MediaUrlsProvider>
      </PurchaseInfoProvider>
    </IsMobileAppViewProvider>,
  );

describe("embedded video playback reporting", () => {
  let playbackEvents: MediaPlaybackEventDetail[];
  const recordPlaybackEvent = (event: Event) => {
    if (isMediaPlaybackEvent(event)) playbackEvents.push(event.detail);
  };

  beforeEach(() => {
    playbackEvents = [];
    window.addEventListener(MEDIA_PLAYBACK_EVENT, recordPlaybackEvent);
  });

  afterEach(() => {
    window.removeEventListener(MEDIA_PLAYBACK_EVENT, recordPlaybackEvent);
    cleanup();
    vi.clearAllMocks();
  });

  it("reports playback for the player it set up", async () => {
    const { player, handlers } = fakePlayer();
    mocks.createJWPlayer.mockResolvedValue(player);

    renderEmbeddedVideoRow();
    fireEvent.click(screen.getByRole("button", { name: "Watch" }));
    await act(async () => Promise.resolve());

    act(() => handlers.get("play")?.());
    expect(playbackEvents).toEqual([{ playerId: PLAYER_ID, isPlaying: true }]);
  });

  // Loading the player library is asynchronous, so an embed can be gone before setup finishes.
  // A player that arrives late must not tell the page a video is playing: the page would stop its
  // media-position poll and never restart it, since nothing is around to report the stop.
  it("does not report playback for a player that finishes setting up after the embed is gone", async () => {
    const { player } = fakePlayer();
    let finishSetup = (_: typeof player) => {};
    mocks.createJWPlayer.mockReturnValue(
      new Promise<typeof player>((resolve) => {
        finishSetup = resolve;
      }),
    );

    renderEmbeddedVideoRow();
    fireEvent.click(screen.getByRole("button", { name: "Watch" }));
    cleanup();
    playbackEvents = [];

    await act(async () => {
      finishSetup(player);
      await Promise.resolve();
    });

    expect(player.on).not.toHaveBeenCalled();
    expect(playbackEvents).toEqual([]);
  });
});
