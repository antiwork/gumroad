import { afterEach, expect, it, vi } from "vitest";

import Countdown from "$app/utils/countdown";

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

it("expires at the original deadline after the browser delays its timer", () => {
  vi.stubEnv("NODE_ENV", "production");
  vi.useFakeTimers();
  vi.setSystemTime(0);
  const onTick = vi.fn();
  const onComplete = vi.fn();
  new Countdown(5, onTick, onComplete, new Date(5_000));

  vi.setSystemTime(8_000);
  vi.advanceTimersByTime(1_000);

  expect(onComplete).toHaveBeenCalledOnce();
  expect(onTick).toHaveBeenCalledExactlyOnceWith(5);
});

it("counts down normally and honors cancellation", () => {
  vi.stubEnv("NODE_ENV", "production");
  vi.useFakeTimers();
  const onTick = vi.fn();
  const onComplete = vi.fn();
  const timer = new Countdown(5, onTick, onComplete);

  vi.advanceTimersByTime(2_000);
  expect(onTick.mock.calls).toEqual([[5], [4], [3]]);
  timer.abort();
  vi.advanceTimersByTime(5_000);
  expect(onComplete).not.toHaveBeenCalled();
});
