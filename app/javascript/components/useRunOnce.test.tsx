// @vitest-environment happy-dom
import { render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { useRunOnce } from "$app/components/useRunOnce";

afterEach(() => {
  vi.restoreAllMocks();
});

describe("useRunOnce", () => {
  it("runs the callback exactly once across re-renders", () => {
    const cb = vi.fn();
    const Component = () => {
      useRunOnce(cb);
      return null;
    };

    const { rerender } = render(<Component />);
    rerender(<Component />);

    expect(cb).toHaveBeenCalledTimes(1);
  });

  it("warns in development when the callback returns what looks like a cleanup function", () => {
    // useRunOnce cannot honour a returned cleanup, and TypeScript will not reject one because a
    // function returning a value is still assignable to a `() => void` parameter. The warning is
    // the only thing standing between that mistake and a silent leak, which is how
    // CopyToClipboard's ClipboardJS instance went un-destroyed.
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    const Component = () => {
      useRunOnce(() => () => {
        /* looks like an effect cleanup */
      });
      return null;
    };

    render(<Component />);

    expect(errors).toHaveBeenCalledTimes(1);
    expect(errors.mock.calls[0]?.[0]).toContain("useRunOnce");
  });

  it("does not warn for a callback that returns nothing", () => {
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    const Component = () => {
      useRunOnce(() => {
        /* no return value */
      });
      return null;
    };

    render(<Component />);

    expect(errors).not.toHaveBeenCalled();
  });
});
