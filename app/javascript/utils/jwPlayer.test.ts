import { beforeEach, describe, expect, it, vi } from "vitest";

const setup = vi.fn((config: unknown) => ({ configured: config }));
const jwplayerGlobal = vi.fn(() => ({ setup }));

describe("createJWPlayer", () => {
  beforeEach(() => {
    vi.resetModules();
    setup.mockClear();
    jwplayerGlobal.mockClear();
    // Stub the global the CDN library script would normally define, so createJWPlayer
    // skips the network import and we can inspect the setup config it builds.
    vi.stubGlobal("jwplayer", jwplayerGlobal);
  });

  it("sets up the player on the given container with the caller's options", async () => {
    const { createJWPlayer } = await import("./jwPlayer");

    const playlist = [{ sources: [{ file: "https://example.com/video.m3u8" }] }];
    await createJWPlayer("player-container", { playlist });

    expect(jwplayerGlobal).toHaveBeenCalledWith("player-container");
    expect(setup).toHaveBeenCalledWith(expect.objectContaining({ playlist }));
  });

  it("disables casting, which cannot work with session-authenticated streams", async () => {
    const { createJWPlayer } = await import("./jwPlayer");

    await createJWPlayer("player-container", { playlist: [] });

    expect(setup).toHaveBeenCalledWith(expect.objectContaining({ cast: false }));
  });

  it("forces the player's own caption renderer so iOS Safari doesn't misposition side-loaded cues", async () => {
    const { createJWPlayer } = await import("./jwPlayer");

    await createJWPlayer("player-container", { playlist: [] });

    expect(setup).toHaveBeenCalledWith(expect.objectContaining({ renderCaptionsNatively: false }));
  });

  it("does not let callers re-enable casting or native caption rendering", async () => {
    const { createJWPlayer } = await import("./jwPlayer");

    await createJWPlayer("player-container", {
      playlist: [],
      // @ts-expect-error cast and renderCaptionsNatively are intentionally not part of JWPlayerOptions
      cast: {},
      renderCaptionsNatively: true,
    });

    expect(setup).toHaveBeenCalledWith(expect.objectContaining({ cast: false, renderCaptionsNatively: false }));
  });
});
