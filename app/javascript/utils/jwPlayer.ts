type Optional<T> = { [k in keyof T]?: T[k] | undefined };

// Patch the options from @types/jwplayer as they do not match the documentation.
// "cast" is omitted because casting is force-disabled in createJWPlayer below —
// callers must not re-enable it per-player.
export type JWPlayerOptions = Omit<jwplayer.SetupConfig, "playlist" | "cast"> & {
  playlist: (Omit<Optional<jwplayer.PlaylistItem>, "file" | "sources"> & {
    sources: (Optional<jwplayer.Source> & Pick<jwplayer.Source, "file">)[];
  })[];
};

export const createJWPlayer = async (containerId: string, options: JWPlayerOptions) => {
  // Load the cloud-hosted player library only if it isn't on the page yet (it defines the
  // global "jwplayer" function). The guard also lets tests provide a stubbed global instead
  // of fetching the real library over the network.
  if (typeof jwplayer === "undefined") {
    // @ts-expect-error no types for dynamic import, but we're not using the return value anyway
    await import(/* @vite-ignore */ "https://cdn.jwplayer.com/libraries/3vz4Z4wu.js");
  }

  // JW Player merges our setup options over the cloud player config (window.jwplayer.defaults,
  // from the library script above), which currently ships with casting enabled ("cast": {}).
  // That renders a Chromecast button that can never actually play our videos: purchased streams
  // are served through session-authenticated endpoints (UrlRedirectsController#hls_playlist /
  // #smil plus signed URLs the client assembles at render time), and a Chromecast receiver
  // fetches the stream itself, without the buyer's cookies — so the cast session connects and
  // then stays black. Until streams are servable via cookie-free tokenized URLs, hide the
  // button instead of shipping a control that silently fails. A falsy "cast" makes the player
  // skip cast setup entirely, so no cast button is rendered.
  // See https://github.com/antiwork/gumroad-private/issues/1051
  // Always let JW Player draw captions itself instead of handing side-loaded .srt/.vtt
  // tracks to the browser's built-in text-track renderer. JW Player's default is
  // browser-specific ("renderCaptionsNatively" is true on Safari, false on Chrome),
  // and Safari on iOS positions natively-rendered side-loaded cues at the right edge
  // of the video instead of centered at the bottom — making captions unreadable for
  // buyers watching purchased videos on iPhones/iPads. Forcing the player's own
  // renderer gives every browser the same centered-bottom captions Chrome already
  // shows. See https://github.com/antiwork/gumroad/issues/6043
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- "cast: false" is the documented way to leave casting un-configured, but the @types/jwplayer CastConfig type doesn't model it
  const setupConfig = { ...options, cast: false, renderCaptionsNatively: false } as unknown as jwplayer.SetupConfig;

  return jwplayer(containerId).setup(setupConfig);
};
