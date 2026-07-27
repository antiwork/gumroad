// @vitest-environment happy-dom
import { act, cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { dispatchMediaPlaybackState } from "$app/utils/media_playback";

const mocks = vi.hoisted(() => ({
  usePage: vi.fn(),
  usePoll: vi.fn(),
}));

vi.mock("@inertiajs/react", () => ({ usePage: mocks.usePage, usePoll: mocks.usePoll }));
vi.mock("$app/hooks/useDropbox", () => ({ useDropbox: () => undefined }));
vi.mock("$app/components/DownloadPage/WithContent", () => ({ WithContent: () => <div /> }));

// typia.assert is generated from the page's prop type, so give the page a shape that satisfies it
// while keeping the fixture small: one video file inside a rich-content page.
const pageProps = () => ({
  content_unavailability_reason_code: null,
  is_mobile_app_web_view: false,
  terms_page_url: "https://gumroad.com/terms",
  token: "token",
  redirect_id: "redirect-1",
  add_to_library_option: "none",
  purchase: null,
  content: {
    rich_content_pages: [],
    last_content_page_id: null,
    license: null,
    content_items: [
      {
        type: "file",
        id: "file-1",
        file_name: "Lecture 1",
        description: null,
        extension: "MP4",
        file_size: 1024,
        pagelength: null,
        duration: 5400,
        content_length: 5400,
        download_url: null,
        latest_media_location: null,
        stream_url: null,
        external_link_url: null,
        kindle_data: null,
        read_url: null,
        pdf_stamp_enabled: false,
        processing: false,
        thumbnail_url: null,
      },
    ],
    posts: [],
    video_transcoding_info: null,
    custom_receipt: null,
    discord: null,
    ios_app_url: "",
    android_app_url: "",
    download_all_button: null,
    community_chat_url: null,
  },
  product_has_third_party_analytics: null,
  seller_analytics: null,
  dropbox_api_key: null,
});

// The page's two polls, identified by their interval rather than by call order: keying on
// position would silently start asserting against the wrong poll if a third one were ever added.
const MEDIA_LOCATIONS_POLL_INTERVAL = 10_000;

type PollFake = { start: ReturnType<typeof vi.fn>; stop: ReturnType<typeof vi.fn> };

describe("DownloadPage media position polling", () => {
  let DownloadPage: React.ComponentType;
  // One persistent fake per interval. The same object has to come back on every render, or
  // calls made during earlier renders would be lost.
  const pollsByInterval = new Map<number, PollFake>();

  beforeEach(async () => {
    pollsByInterval.clear();
    mocks.usePoll.mockImplementation((interval: number) => {
      const existing = pollsByInterval.get(interval);
      if (existing) return existing;
      const poll: PollFake = { start: vi.fn(), stop: vi.fn() };
      pollsByInterval.set(interval, poll);
      return poll;
    });
    // typia.assert runs for real against this fixture, so it doubles as a check that the
    // fixture still satisfies the page's prop contract.
    mocks.usePage.mockReturnValue({ props: pageProps() });
    DownloadPage = (await import("$app/pages/UrlRedirects/DownloadPage")).default;
  });

  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  const mediaLocationsPoll = () => pollsByInterval.get(MEDIA_LOCATIONS_POLL_INTERVAL);

  // Guards the lookup above: if the page's poll interval changes, every assertion below would
  // silently be reading an absent poll and passing on optional chaining.
  it("registers a media-positions poll on the expected interval", () => {
    render(<DownloadPage />);

    expect(mediaLocationsPoll()).toBeDefined();
  });

  it("polls for media positions while nothing is playing", () => {
    render(<DownloadPage />);

    expect(mediaLocationsPoll()?.start).toHaveBeenCalled();
  });

  it("stops polling for media positions while a video is playing, and resumes when it stops", () => {
    render(<DownloadPage />);
    mediaLocationsPoll()?.start.mockClear();
    mediaLocationsPoll()?.stop.mockClear();

    act(() => {
      dispatchMediaPlaybackState("jwplayer-file-1", true);
    });
    expect(mediaLocationsPoll()?.stop).toHaveBeenCalled();
    expect(mediaLocationsPoll()?.start).not.toHaveBeenCalled();

    act(() => {
      dispatchMediaPlaybackState("jwplayer-file-1", false);
    });
    expect(mediaLocationsPoll()?.start).toHaveBeenCalled();
  });

  // A content page can embed several videos. One of them stopping must not resume the poll
  // while another is still playing.
  it("keeps the poll paused while a second player is still playing", () => {
    render(<DownloadPage />);

    act(() => {
      dispatchMediaPlaybackState("jwplayer-file-1", true);
      dispatchMediaPlaybackState("jwplayer-file-2", true);
    });
    mediaLocationsPoll()?.start.mockClear();

    act(() => {
      dispatchMediaPlaybackState("jwplayer-file-1", false);
    });
    expect(mediaLocationsPoll()?.start).not.toHaveBeenCalled();

    act(() => {
      dispatchMediaPlaybackState("jwplayer-file-2", false);
    });
    expect(mediaLocationsPoll()?.start).toHaveBeenCalled();
  });

  it("ignores a repeated playing event from the same player", () => {
    render(<DownloadPage />);

    act(() => {
      dispatchMediaPlaybackState("jwplayer-file-1", true);
    });
    mediaLocationsPoll()?.start.mockClear();

    // JW Player fires "play" again after each seek; a duplicate must not double-count the
    // player, or the matching single "pause" would leave the poll paused forever.
    act(() => {
      dispatchMediaPlaybackState("jwplayer-file-1", true);
      dispatchMediaPlaybackState("jwplayer-file-1", false);
    });
    expect(mediaLocationsPoll()?.start).toHaveBeenCalled();
  });
});
