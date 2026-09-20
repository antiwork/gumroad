import { describe, expect, it } from "vitest";

import { isFinishedMediaLocation, isResumableMediaLocation, persistableMediaLocation } from "$app/utils/mediaLocation";

describe("isFinishedMediaLocation", () => {
  it("treats a position in the last 30 seconds of a long session as finished", () => {
    expect(isFinishedMediaLocation(3690, 3711)).toBe(true);
    expect(isFinishedMediaLocation(3681, 3711)).toBe(true);
  });

  it("does not treat a mid-track position as finished", () => {
    expect(isFinishedMediaLocation(3600, 3711)).toBe(false);
    expect(isFinishedMediaLocation(1209, 1800)).toBe(false);
  });

  it("uses a 5% window on short files so mid-track progress stays resumable", () => {
    expect(isFinishedMediaLocation(40, 60)).toBe(false);
    expect(isFinishedMediaLocation(57, 60)).toBe(true);
    expect(isFinishedMediaLocation(8, 10)).toBe(false);
    expect(isFinishedMediaLocation(9.6, 10)).toBe(true);
  });

  it("treats an exact end as finished", () => {
    expect(isFinishedMediaLocation(3711, 3711)).toBe(true);
  });

  it("is not finished when location or length is missing", () => {
    expect(isFinishedMediaLocation(null, 3711)).toBe(false);
    expect(isFinishedMediaLocation(3690, null)).toBe(false);
    expect(isFinishedMediaLocation(3690, 0)).toBe(false);
  });
});

describe("isResumableMediaLocation", () => {
  it("rejects missing, zero, and near-end locations", () => {
    expect(isResumableMediaLocation(undefined, 3711)).toBe(false);
    expect(isResumableMediaLocation(0, 3711)).toBe(false);
    expect(isResumableMediaLocation(3690, 3711)).toBe(false);
  });

  it("accepts a mid-track location", () => {
    expect(isResumableMediaLocation(1209, 1800)).toBe(true);
  });

  it("accepts any positive location when length is unknown", () => {
    expect(isResumableMediaLocation(120, undefined)).toBe(true);
    expect(isResumableMediaLocation(120, 0)).toBe(true);
  });
});

describe("persistableMediaLocation", () => {
  it("stores a near-end position as the finished length", () => {
    expect(persistableMediaLocation(3690, 3711)).toBe(3711);
  });

  it("keeps a mid-track position", () => {
    expect(persistableMediaLocation(1209, 1800)).toBe(1209);
  });

  it("caps past-the-end positions at the length", () => {
    expect(persistableMediaLocation(4000, 3711)).toBe(3711);
  });

  it("passes the position through when length is unknown", () => {
    expect(persistableMediaLocation(42, null)).toBe(42);
  });
});
