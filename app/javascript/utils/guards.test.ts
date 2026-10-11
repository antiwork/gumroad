import { describe, expect, it } from "vitest";

import {
  assertNullableString,
  assertOptionalString,
  assertString,
  hasType,
  isBoolean,
  isNumber,
  isOneOf,
  isRecord,
  isRecordOf,
  isString,
} from "$app/utils/guards";

describe("guards", () => {
  it("accepts plain objects as records, and rejects null, arrays and primitives", () => {
    expect(isRecord({})).toBe(true);
    expect(isRecord({ a: 1 })).toBe(true);
    expect(isRecord(null)).toBe(false);
    expect(isRecord([])).toBe(false);
    expect(isRecord("x")).toBe(false);
  });

  it("accepts only finite numbers", () => {
    expect(isNumber(0)).toBe(true);
    expect(isNumber(-1.5)).toBe(true);
    expect(isNumber(Number.NaN)).toBe(false);
    expect(isNumber(Number.POSITIVE_INFINITY)).toBe(false);
    expect(isNumber("1")).toBe(false);
  });

  it("checks strings and booleans by type only", () => {
    expect(isString("")).toBe(true);
    expect(isString(1)).toBe(false);
    expect(isBoolean(false)).toBe(true);
    expect(isBoolean("false")).toBe(false);
  });

  it("accepts only the listed strings", () => {
    expect(isOneOf("asc", ["asc", "desc"])).toBe(true);
    expect(isOneOf("up", ["asc", "desc"])).toBe(false);
    expect(isOneOf(1, ["asc", "desc"])).toBe(false);
  });

  it("matches an object by its type field", () => {
    expect(hasType({ type: "height", height: 10 }, "height")).toBe(true);
    expect(hasType({ type: "loaded" }, "height")).toBe(false);
    expect(hasType("height", "height")).toBe(false);
    expect(hasType(null, "height")).toBe(false);
  });

  it("accepts a record only when every value passes the check", () => {
    expect(isRecordOf({ a: "x", b: "y" }, isString)).toBe(true);
    expect(isRecordOf({}, isString)).toBe(true);
    expect(isRecordOf({ a: "x", b: 1 }, isString)).toBe(false);
    expect(isRecordOf(["x"], isString)).toBe(false);
  });

  it("returns strings and throws on any other type", () => {
    expect(assertString("a")).toBe("a");
    expect(() => assertString(["javascript:alert(1)"])).toThrow(TypeError);
    expect(() => assertString(null)).toThrow(TypeError);
    expect(assertNullableString(null)).toBeNull();
    expect(() => assertNullableString(undefined)).toThrow(TypeError);
    expect(assertOptionalString(undefined)).toBeUndefined();
    expect(assertOptionalString(null)).toBeNull();
    expect(() => assertOptionalString(1)).toThrow(TypeError);
  });
});
