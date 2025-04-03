type Optional<T> = { [k in keyof T]?: T[k] | undefined };

// Patch the options from @types/jwplayer as they do not match the documentation
export type JWPlayerOptions = Omit<jwplayer.SetupConfig, "playlist"> & {
  playlist: (Omit<Optional<jwplayer.PlaylistItem>, "file" | "sources"> & {
    sources: (Optional<jwplayer.Source> & Pick<jwplayer.Source, "file">)[];
  })[];
};

export const createJWPlayer = async (containerId: string, options: JWPlayerOptions) => {
  // @ts-expect-error no types for dynamic import, but we're not using the return value anyway
  await import(/* webpackIgnore: true */ "https://cdn.jwplayer.com/libraries/3vz4Z4wu.js");

  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- see type above
  return jwplayer(containerId).setup(options as jwplayer.SetupConfig);
};
