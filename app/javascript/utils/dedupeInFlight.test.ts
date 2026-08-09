import { describe, expect, it } from "vitest";

import { dedupeInFlight } from "$app/utils/dedupeInFlight";

describe("dedupeInFlight", () => {
  it("shares one in-flight call across overlapping invocations", async () => {
    let calls = 0;
    let resolve: (() => void) | undefined;
    const fn = dedupeInFlight(
      () =>
        new Promise<number>((res) => {
          calls++;
          resolve = () => res(calls);
        }),
    );

    const first = fn();
    const second = fn();
    expect(calls).toBe(1);

    resolve?.();
    await expect(first).resolves.toBe(1);
    await expect(second).resolves.toBe(1);
  });

  it("starts a fresh call once the previous one has settled", async () => {
    let calls = 0;
    const fn = dedupeInFlight(() => Promise.resolve(++calls));

    await expect(fn()).resolves.toBe(1);
    await expect(fn()).resolves.toBe(2);
    expect(calls).toBe(2);
  });

  it("clears the in-flight slot even when the call rejects", async () => {
    let calls = 0;
    const fn = dedupeInFlight(() => {
      calls++;
      return calls === 1 ? Promise.reject(new Error("boom")) : Promise.resolve(calls);
    });

    await expect(fn()).rejects.toThrow("boom");
    await expect(fn()).resolves.toBe(2);
  });
});
