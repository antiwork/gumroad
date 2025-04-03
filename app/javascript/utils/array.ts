export function isTuple<T, N extends number>(array: T[], length: N): array is Tuple<T, N> {
  return array.length === length;
}

export function isOpenTuple<T, N extends number>(array: T[], length: N): array is [...Tuple<T, N>, ...T[]] {
  return array.length >= length;
}

export function last<T>(array: readonly [T, ...T[]]): T {
  // eslint-disable-next-line @typescript-eslint/no-non-null-assertion
  return array[array.length - 1]!;
}
