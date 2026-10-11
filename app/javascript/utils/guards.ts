// Runtime checks for values from outside the app: postMessage data, history state, storage,
// websocket frames and third-party responses. Our own server's JSON is typed, not checked.

export const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

export const isString = (value: unknown): value is string => typeof value === "string";

export const isNumber = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

export const isBoolean = (value: unknown): value is boolean => typeof value === "boolean";

export const isOneOf = <T extends string>(value: unknown, options: readonly T[]): value is T =>
  typeof value === "string" && options.some((option) => option === value);

export const isRecordOf = <T>(value: unknown, check: (item: unknown) => item is T): value is Record<string, T> =>
  isRecord(value) && Object.values(value).every(check);

export const hasType = <T extends string>(value: unknown, type: T): value is Record<string, unknown> & { type: T } =>
  isRecord(value) && value.type === type;

// For values that must have the type before they are used, such as seller-written rich content
// attributes that end up in the DOM. Each one throws when the value has another type.
export const assertString = (value: unknown): string => {
  if (!isString(value)) throw new TypeError(`Expected a string, got ${typeof value}`);
  return value;
};

export const assertNullableString = (value: unknown): string | null => (value === null ? null : assertString(value));

export const assertOptionalString = (value: unknown): string | null | undefined =>
  value === null || value === undefined ? value : assertString(value);
