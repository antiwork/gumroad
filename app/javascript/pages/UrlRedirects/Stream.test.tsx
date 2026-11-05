// @vitest-environment happy-dom
import { act, cleanup, render, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { trackMediaLocationChanged } from "$app/data/media_location";
import Stream from "$app/pages/UrlRedirects/Stream";
import { createJWPlayer } from "$app/utils/jwPlayer";

const { handlers, player, props } = vi.hoisted(() => {
  const handlers: Record<string, (event?: unknown) => void> = {};
  const player = {
    on: vi.fn(),
    getDuration: () => 3711,
    getPlaylistIndex: () => 0,
    seek: vi.fn(),
    remove: vi.fn(),
    playlistItem: vi.fn(),
  };
  player.on.mockImplementation((name: string, callback: (event?: unknown) => void) => {
    handlers[name] = callback;
    return player;
  });
  return {
    handlers,
    player,
    props: {
      playlist: [
        {
          sources: [],
          guid: "file-guid",
          title: "Session",
          tracks: [],
          external_id: "file-1",
          latest_media_location: { location: 3690 },
          content_length: null,
        },
        {
          // A null guid never arrives with the placeholder in practice; the guard is what keeps
          // String.replace from being handed null, so the placeholder has to come back untouched.
          sources: ["https://example.com/attachments/ef64f2fef0d6c776a337050020423fc0/original/session.mp4"],
          guid: null,
          title: "Outside the attachments layout",
          tracks: [],
          external_id: "file-2",
          latest_media_location: null,
          content_length: null,
        },
      ],
      index_to_play: 0,
      url_redirect_id: "redirect-1",
      purchase_id: "purchase-1",
      should_show_transcoding_notice: false,
      transcode_on_first_sale: false,
    },
  };
});
vi.mock("@inertiajs/react", () => ({ usePage: () => ({ props }) }));
vi.mock("$app/utils/jwPlayer", () => ({ createJWPlayer: vi.fn().mockResolvedValue(player) }));
vi.mock("$app/data/media_location", () => ({ trackMediaLocationChanged: vi.fn() }));
vi.mock("$app/data/consumption_analytics", () => ({ createConsumptionEvent: vi.fn() }));
vi.mock("$app/components/Download/TranscodingNoticeModal", () => ({ TranscodingNoticeModal: () => null }));
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

it("uses player duration for a nullable-length initial seek and progress write", async () => {
  render(<Stream />);
  await waitFor(() => expect(handlers.visualQuality).toBeDefined());
  act(() => {
    handlers.play?.();
    handlers.visualQuality?.();
  });
  expect(player.seek).not.toHaveBeenCalled();
  act(() => handlers.time?.({ position: 3690, duration: 3711 }));
  expect(trackMediaLocationChanged).toHaveBeenLastCalledWith(expect.objectContaining({ location: 3711 }));
});

it("skips the placeholder replacement when the file has no guid", async () => {
  render(<Stream />);
  await waitFor(() => expect(createJWPlayer).toHaveBeenCalled());
  const options = vi.mocked(createJWPlayer).mock.calls[0]?.[1];
  const playlist = options?.playlist ?? [];
  expect(playlist.map((video) => video.sources.map((source) => source.file))).toContainEqual([
    "https://example.com/attachments/ef64f2fef0d6c776a337050020423fc0/original/session.mp4",
  ]);
});
