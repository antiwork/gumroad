import { expect, it } from "vitest";

import { check } from "./index.ts";

// A program per file resolves GlobalShape to `any`, and then check() accepts anything.
it("checks a field of a type declared only in a global .d.ts", () => {
  expect(check({ count: 1 })).toEqual({ count: 1 });
  expect(() => check({ count: "1" })).toThrow();
});
