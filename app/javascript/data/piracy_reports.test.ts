import { describe, expect, it } from "vitest";

import { restorationDeadline } from "$app/data/piracy_reports";

describe("restorationDeadline", () => {
  const window: [string, string] = ["2026-10-23", "2026-10-29"];

  it("names the first day of the window as the deadline", () => {
    expect(restorationDeadline(window, new Date("2026-10-22T23:59:59Z"))).toEqual({ day: "2026-10-23", passed: false });
  });

  it("passes on the first day, and stays passed between the two dates", () => {
    expect(restorationDeadline(window, new Date("2026-10-23T00:00:00Z"))).toEqual({ day: "2026-10-23", passed: true });
    expect(restorationDeadline(window, new Date("2026-10-26T12:00:00Z"))).toEqual({ day: "2026-10-23", passed: true });
  });
});
