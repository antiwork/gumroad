// Types a value without checking it. Use it only for data our own server produced (Inertia props,
// JSON responses); check anything from outside the app with $app/utils/guards.
// eslint-disable-next-line @typescript-eslint/no-unnecessary-type-parameters -- the caller picks T
export const cast = <T>(value: unknown): T =>
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- the one unchecked cast, see above
  value as T;
