export function assert(condition: boolean, msg = "Assertion failed"): asserts condition {
  if (!condition) {
    throw new Error(msg);
  }
}

export function assertDefined<T>(value: T, msg?: string): NonNullable<T> {
  assert(value != null, msg);
  return value;
}
