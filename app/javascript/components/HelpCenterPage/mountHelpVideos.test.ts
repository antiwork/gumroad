// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createJWPlayer: vi.fn(),
  trackHelpVideoEvent: vi.fn(),
}));

vi.mock("$app/utils/jwPlayer", () => ({
  createJWPlayer: mocks.createJWPlayer,
}));

vi.mock("$app/data/google_analytics", () => ({
  trackHelpVideoEvent: mocks.trackHelpVideoEvent,
}));

type Handler = (event?: { position: number; duration: number }) => void;

const makePlayer = () => {
  const handlers: Record<string, Handler> = {};
  return {
    on: vi.fn((event: string, handler: Handler) => {
      handlers[event] = handler;
    }),
    remove: vi.fn(),
    handlers,
  };
};

describe("mountHelpVideos", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
    mocks.createJWPlayer.mockReset();
    mocks.trackHelpVideoEvent.mockReset();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("sets up JW Player for each help video placeholder", async () => {
    const { mountHelpVideos } = await import("./mountHelpVideos");
    const player = makePlayer();
    mocks.createJWPlayer.mockResolvedValue(player);

    document.body.innerHTML = `
      <div
        data-help-video="beginner-walkthrough"
        data-help-video-src="/images/help_center/beginner-walkthrough.mp4"
        data-help-video-poster="/images/help_center/beginner-walkthrough.jpg"
        data-help-video-title="Beginner walkthrough: set up a course"
      ></div>
    `;

    const cleanup = mountHelpVideos(document.body);
    await Promise.resolve();

    expect(mocks.createJWPlayer).toHaveBeenCalledWith(
      "help-video-0",
      expect.objectContaining({
        width: "100%",
        aspectratio: "16:9",
        playlist: [
          {
            sources: [{ file: "/images/help_center/beginner-walkthrough.mp4" }],
            title: "Beginner walkthrough: set up a course",
            image: "/images/help_center/beginner-walkthrough.jpg",
          },
        ],
      }),
    );

    cleanup();
    expect(player.remove).toHaveBeenCalled();
  });

  it("tracks start, progress marks, and complete once each", async () => {
    const { mountHelpVideos } = await import("./mountHelpVideos");
    const player = makePlayer();
    mocks.createJWPlayer.mockResolvedValue(player);

    document.body.innerHTML = `
      <div
        data-help-video="beginner-walkthrough"
        data-help-video-src="/video.mp4"
        data-help-video-title="Walkthrough"
      ></div>
    `;

    mountHelpVideos(document.body);
    await Promise.resolve();

    player.handlers.play?.();
    player.handlers.play?.();
    player.handlers.time?.({ position: 40, duration: 100 });
    player.handlers.time?.({ position: 51, duration: 100 });
    player.handlers.time?.({ position: 80, duration: 100 });
    player.handlers.complete?.();

    expect(mocks.trackHelpVideoEvent.mock.calls).toEqual([
      ["video_start", { videoId: "beginner-walkthrough", title: "Walkthrough", url: "/video.mp4" }],
      ["video_progress", { videoId: "beginner-walkthrough", title: "Walkthrough", url: "/video.mp4", percent: 25 }],
      ["video_progress", { videoId: "beginner-walkthrough", title: "Walkthrough", url: "/video.mp4", percent: 50 }],
      ["video_progress", { videoId: "beginner-walkthrough", title: "Walkthrough", url: "/video.mp4", percent: 75 }],
      ["video_complete", { videoId: "beginner-walkthrough", title: "Walkthrough", url: "/video.mp4", percent: 100 }],
    ]);
  });

  it("skips placeholders that are missing a source", async () => {
    const { mountHelpVideos } = await import("./mountHelpVideos");

    document.body.innerHTML = `<div data-help-video="missing-src"></div>`;

    mountHelpVideos(document.body);
    await Promise.resolve();

    expect(mocks.createJWPlayer).not.toHaveBeenCalled();
  });
});
