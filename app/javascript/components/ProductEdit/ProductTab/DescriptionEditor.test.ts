// @vitest-environment happy-dom
import { describe, expect, it } from "vitest";

import { ResponseError } from "$app/utils/request";

import { publicFileIdFromResponse } from "$app/components/ProductEdit/ProductTab/DescriptionEditor";

describe("publicFileIdFromResponse", () => {
  it("returns the id of a saved public file", () => {
    expect(publicFileIdFromResponse({ success: true, id: "pf_1" })).toBe("pf_1");
  });

  it("throws for a file the server could not save, although it answered 200", () => {
    expect(() => publicFileIdFromResponse({ success: false, error: "File is too large" })).toThrow(ResponseError);
    expect(() => publicFileIdFromResponse({ success: true })).toThrow(ResponseError);
  });
});
