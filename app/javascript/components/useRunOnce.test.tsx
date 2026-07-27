// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { useRunOnce } from "$app/components/useRunOnce";

afterEach(cleanup);

const Harness = ({ cb }: { cb: () => undefined | (() => void) }) => {
  useRunOnce(cb);
  return <span>mounted</span>;
};

describe("useRunOnce", () => {
  it("runs the callback exactly once across re-renders", () => {
    const cb = vi.fn();
    const { rerender } = render(<Harness cb={cb} />);

    rerender(<Harness cb={cb} />);
    rerender(<Harness cb={cb} />);

    expect(cb).toHaveBeenCalledTimes(1);
  });

  // The reason this hook exists is to set up things that live for the page's lifetime — event
  // listeners, ClipboardJS instances. Those have to be torn down, and the returned cleanup was
  // being dropped, so every one of them leaked. CopyToClipboard was the caller that noticed.
  it("runs a returned cleanup function on unmount", () => {
    const cleanupFn = vi.fn();
    const { unmount } = render(<Harness cb={() => cleanupFn} />);

    expect(cleanupFn).not.toHaveBeenCalled();

    unmount();

    expect(cleanupFn).toHaveBeenCalledTimes(1);
  });

  it("does not run the cleanup on a re-render, only on unmount", () => {
    const cleanupFn = vi.fn();
    const { rerender, unmount } = render(<Harness cb={() => cleanupFn} />);

    rerender(<Harness cb={() => cleanupFn} />);
    expect(cleanupFn).not.toHaveBeenCalled();

    unmount();
    expect(cleanupFn).toHaveBeenCalledTimes(1);
  });

  it("tolerates a callback that returns nothing", () => {
    const { unmount } = render(<Harness cb={() => undefined} />);

    // The point is that unmounting a caller with no cleanup must not throw.
    expect(() => unmount()).not.toThrow();
    expect(screen.queryByText("mounted")).toBeNull();
  });
});
