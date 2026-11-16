import { describe, expect, it } from "vitest";

import { SUBTITLE_LANGUAGES } from "$app/utils/subtitle_languages";

describe("SUBTITLE_LANGUAGES", () => {
  it("includes Finnish, Slovak and Bulgarian", () => {
    expect(SUBTITLE_LANGUAGES).toEqual(expect.arrayContaining(["Suomi", "Slovenčina", "български"]));
  });

  it("has no duplicate entries", () => {
    expect(new Set(SUBTITLE_LANGUAGES).size).toBe(SUBTITLE_LANGUAGES.length);
  });
});
