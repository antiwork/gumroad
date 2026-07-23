import { describe, it, expect } from "vitest";

import { humanizedDuration } from "$app/utils/duration";

describe("humanizedDuration", () => {
  it("formats sub-minute durations as minutes and seconds", () => {
    expect(humanizedDuration(0)).toBe("0m 0s");
    expect(humanizedDuration(45)).toBe("0m 45s");
  });

  it("formats sub-hour durations as minutes and seconds", () => {
    expect(humanizedDuration(60)).toBe("1m 0s");
    expect(humanizedDuration(59 * 60 + 59)).toBe("59m 59s");
  });

  it("formats durations of an hour or more as hours and minutes", () => {
    expect(humanizedDuration(3600)).toBe("1h 0m");
    expect(humanizedDuration(3600 + 90)).toBe("1h 1m");
    expect(humanizedDuration(23 * 3600 + 59 * 60)).toBe("23h 59m");
  });

  it("does not wrap at 24 hours (long-form audio regression)", () => {
    expect(humanizedDuration(24 * 3600)).toBe("24h 0m");
    expect(humanizedDuration(25 * 3600)).toBe("25h 0m");
    expect(humanizedDuration(49 * 3600 + 30 * 60)).toBe("49h 30m");
  });

  it("floors fractional seconds", () => {
    expect(humanizedDuration(89.7)).toBe("1m 29s");
  });
});
