// @vitest-environment happy-dom
import { act, cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import ToastAlert, { DISMISS_DELAY_MS } from "$app/components/server-components/Alert";

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("ToastAlert", () => {
  it("clears the initial dismiss timeout when it unmounts", () => {
    // Regression for #6433: the initial timer was started from useRunOnce with no cleanup, so an
    // unmount before the 5-second fire left a dangling timeout that would call setState later.
    vi.useFakeTimers();
    const clearTimeoutSpy = vi.spyOn(window, "clearTimeout");
    const setTimeoutSpy = vi.spyOn(window, "setTimeout");

    const { unmount } = render(<ToastAlert initial={{ message: "Saved", status: "success" }} />);

    // The component starts exactly one 5-second dismiss timer for the initial payload.
    const dismissTimers = setTimeoutSpy.mock.calls.filter(([, delay]) => delay === DISMISS_DELAY_MS);
    expect(dismissTimers).toHaveLength(1);
    expect(clearTimeoutSpy).not.toHaveBeenCalled();

    unmount();

    expect(clearTimeoutSpy).toHaveBeenCalled();
  });

  it("does not start a dismiss timeout when there is no initial alert", () => {
    vi.useFakeTimers();
    const setTimeoutSpy = vi.spyOn(window, "setTimeout");

    render(<ToastAlert initial={null} />);

    // Other libraries may schedule timers; assert none of ours is the 5-second dismiss.
    const dismissTimers = setTimeoutSpy.mock.calls.filter(([, delay]) => delay === DISMISS_DELAY_MS);
    expect(dismissTimers).toHaveLength(0);
  });

  const post = (data: unknown) =>
    act(() => {
      window.dispatchEvent(new MessageEvent("message", { data, origin: window.location.origin }));
    });

  it("shows an alert posted by showAlert's message shape", () => {
    render(<ToastAlert initial={null} />);

    post({ type: "alert", payload: { message: "Changes saved", status: "success", html: false, position: undefined } });

    expect(screen.getByText("Changes saved")).toBeTruthy();
  });

  it("ignores an alert message whose payload has the wrong shape", () => {
    render(<ToastAlert initial={null} />);

    post({ type: "alert", payload: { message: "Not shown", status: "bogus" } });
    post({ type: "alert", payload: { status: "success" } });

    expect(screen.queryByText("Not shown")).toBeNull();
  });
});
