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
  // @ts-expect-error no types for dynamic import, but we're not using the return value anyway
  await import(/* @vite-ignore */ "https://cdn.jwplayer.com/libraries/3vz4Z4wu.js");

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
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- "cast: false" is the documented way to leave casting un-configured, but the @types/jwplayer CastConfig type doesn't model it
  const setupConfig = { ...options, cast: false } as unknown as jwplayer.SetupConfig;

  return jwplayer(containerId).setup(setupConfig);
};
