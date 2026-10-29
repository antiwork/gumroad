// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const setup = vi.fn((config: unknown) => ({ configured: config }));
const jwplayerGlobal = vi.fn(() => ({ setup }));

const LIBRARY_URL = "https://cdn.jwplayer.com/libraries/3vz4Z4wu.js";

// happy-dom cannot load an external script, so the tests take the tag the loader appends and drive
// its events themselves. Each entry is one request the browser would have made.
const captureLibraryScripts = () => {
  const scripts: HTMLScriptElement[] = [];
  vi.spyOn(document.head, "appendChild").mockImplementation((node: Node) => {
    if (node instanceof HTMLScriptElement) scripts.push(node);
    return node;
  });
  return scripts;
};

const requestedScript = (scripts: HTMLScriptElement[], index = 0) => {
  const script = scripts[index];
  if (!script) throw new Error(`no library script was requested at index ${index}`);
  return script;
};

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

describe("createJWPlayer when the library is not on the page yet", () => {
  beforeEach(() => {
    vi.resetModules();
    setup.mockClear();
    jwplayerGlobal.mockClear();
    vi.unstubAllGlobals();
    document.head.innerHTML = "";
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("requests the library, then sets the player up once it arrives", async () => {
    const scripts = captureLibraryScripts();
    const { createJWPlayer } = await import("./jwPlayer");

    const player = createJWPlayer("player-container", { playlist: [] });
    expect(requestedScript(scripts).src).toBe(LIBRARY_URL);

    // What the vendor's script does when it runs.
    vi.stubGlobal("jwplayer", jwplayerGlobal);
    requestedScript(scripts).dispatchEvent(new Event("load"));

    await player;
    expect(jwplayerGlobal).toHaveBeenCalledWith("player-container");
  });

  it("rejects, and takes its tag back off the page, when the library cannot be fetched", async () => {
    const scripts = captureLibraryScripts();
    const { createJWPlayer } = await import("./jwPlayer");

    const player = createJWPlayer("player-container", { playlist: [] });
    const remove = vi.spyOn(requestedScript(scripts), "remove");
    requestedScript(scripts).dispatchEvent(new Event("error"));

    await expect(player).rejects.toThrow(/player library/u);
    expect(remove).toHaveBeenCalled();
  });

  // A failed dynamic import is remembered by the browser's module map, so an import-based retry
  // resolves to the same rejection without a second request and the buyer cannot recover without
  // reloading the page. Each attempt has to be its own request.
  it("requests the library again on the next attempt after a failure", async () => {
    const scripts = captureLibraryScripts();
    const { createJWPlayer } = await import("./jwPlayer");

    const failed = createJWPlayer("player-container", { playlist: [] });
    requestedScript(scripts).dispatchEvent(new Event("error"));
    await expect(failed).rejects.toThrow(/player library/u);

    const retry = createJWPlayer("player-container", { playlist: [] });
    expect(scripts).toHaveLength(2);
    expect(requestedScript(scripts, 1).src).toBe(LIBRARY_URL);

    vi.stubGlobal("jwplayer", jwplayerGlobal);
    requestedScript(scripts, 1).dispatchEvent(new Event("load"));

    await retry;
    expect(jwplayerGlobal).toHaveBeenCalledWith("player-container");
  });

  it("requests the library once for embeds that start together", async () => {
    const scripts = captureLibraryScripts();
    const { createJWPlayer } = await import("./jwPlayer");

    const players = [
      createJWPlayer("player-container-1", { playlist: [] }),
      createJWPlayer("player-container-2", { playlist: [] }),
    ];
    expect(scripts).toHaveLength(1);

    vi.stubGlobal("jwplayer", jwplayerGlobal);
    requestedScript(scripts).dispatchEvent(new Event("load"));

    await Promise.all(players);
    expect(jwplayerGlobal).toHaveBeenCalledTimes(2);
  });
});
