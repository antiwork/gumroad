// @vitest-environment happy-dom

import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { useDedupeInFlight } from "$app/utils/dedupeInFlight";

afterEach(cleanup);

describe("useDedupeInFlight", () => {
  it("shares one in-flight call across overlapping invocations", async () => {
    let resolve: ((value: number) => void) | undefined;
    const fn = vi.fn(() => new Promise<number>((resolvePromise) => (resolve = resolvePromise)));
    const { result } = renderHook(() => useDedupeInFlight("same", fn, () => true));

    let first: Promise<number> | undefined;
    let second: Promise<number> | undefined;
    act(() => {
      first = result.current();
      second = result.current();
    });

    await waitFor(() => expect(fn).toHaveBeenCalledOnce());
    expect(second).toBe(first);

    await act(async () => {
      resolve?.(1);
      await first;
    });
    await expect(second).resolves.toBe(1);
  });

  it("starts a fresh call once the previous one has settled", async () => {
    const fn = vi.fn().mockResolvedValueOnce(1).mockResolvedValueOnce(2);
    const { result } = renderHook(() => useDedupeInFlight("same", fn, () => true));

    await act(async () => await expect(result.current()).resolves.toBe(1));
    await act(async () => await expect(result.current()).resolves.toBe(2));
    expect(fn).toHaveBeenCalledTimes(2);
  });

  it("clears the in-flight slot even when the call rejects", async () => {
    const fn = vi.fn().mockRejectedValueOnce(new Error("boom")).mockResolvedValueOnce(2);
    const { result } = renderHook(() => useDedupeInFlight("same", fn, () => true));

    await act(async () => await expect(result.current()).rejects.toThrow("boom"));
    await act(async () => await expect(result.current()).resolves.toBe(2));
  });

  it("queues changed state until the active call settles", async () => {
    const resolvers: ((value: string) => void)[] = [];
    const fn = vi.fn(
      (value: string) => new Promise<string>((resolvePromise) => resolvers.push(() => resolvePromise(value))),
    );
    const { result, rerender } = renderHook(
      ({ value }) =>
        useDedupeInFlight(
          value,
          () => fn(value),
          () => true,
        ),
      { initialProps: { value: "first" } },
    );

    let first: Promise<string> | undefined;
    act(() => {
      first = result.current();
    });
    await waitFor(() => expect(fn).toHaveBeenCalledOnce());

    rerender({ value: "second" });
    let second: Promise<string> | undefined;
    act(() => {
      second = result.current();
    });
    expect(fn).toHaveBeenCalledOnce();

    await act(async () => {
      resolvers[0]?.("first");
      await first;
    });
    await waitFor(() => expect(fn).toHaveBeenCalledTimes(2));
    expect(fn).toHaveBeenLastCalledWith("second");

    await act(async () => {
      resolvers[1]?.("second");
      await second;
    });
    await expect(second).resolves.toBe("second");
  });

  it("does not run queued state when the active result fails the gate", async () => {
    let resolve: ((value: boolean) => void) | undefined;
    const fn = vi.fn(() => new Promise<boolean>((resolvePromise) => (resolve = resolvePromise)));
    const { result, rerender } = renderHook(({ key }) => useDedupeInFlight(key, fn, (succeeded) => succeeded), {
      initialProps: { key: "first" },
    });

    let first: Promise<boolean> | undefined;
    act(() => {
      first = result.current();
    });
    await waitFor(() => expect(fn).toHaveBeenCalledOnce());

    rerender({ key: "second" });
    let second: Promise<boolean> | undefined;
    act(() => {
      second = result.current();
    });

    await act(async () => {
      resolve?.(false);
      await first;
    });
    await expect(second).resolves.toBe(false);
    expect(fn).toHaveBeenCalledOnce();
  });
});
