export function asyncVoid<T extends unknown[]>(fn: (...args: T) => Promise<void>) {
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions
  return fn as (...args: T) => void;
}
