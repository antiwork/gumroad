// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CopyToClipboard } from "$app/components/CopyToClipboard";

// ClipboardJS needs a real clipboard and a real selection, neither of which happy-dom provides.
// The component's contract with it is narrow — construct against the wrapper element, flip to
// "copied" on success, destroy on unmount — so a fake that captures the success handler covers
// exactly what these tests are about.
const clipboardInstances: { destroy: ReturnType<typeof vi.fn>; fireSuccess: () => void }[] = [];

vi.mock("clipboard", () => ({
  default: class FakeClipboard {
    handlers: Record<string, ((event: { clearSelection: () => void }) => void)[]> = {};
    destroy = vi.fn();

    constructor() {
      clipboardInstances.push({
        destroy: this.destroy,
        fireSuccess: () => this.handlers.success?.forEach((h) => h({ clearSelection: () => {} })),
      });
    }

    on(event: string, handler: (e: { clearSelection: () => void }) => void) {
      (this.handlers[event] ??= []).push(handler);
      return this;
    }
  },
}));

afterEach(() => {
  clipboardInstances.length = 0;
  cleanup();
});

describe("CopyToClipboard", () => {
  // Sighted users get the tooltip flipping to "Copied!". That is a change to text already
  // referenced by aria-describedby, which is not an announced event, so screen-reader users got
  // no confirmation at all. The live region is the announcement.
  it("announces the copy through a live region only after a successful copy", () => {
    render(
      <CopyToClipboard text="secret-key" copiedTooltip="Copied!">
        <button>Copy</button>
      </CopyToClipboard>,
    );

    const liveRegion = screen.getByRole("status");
    expect(liveRegion.textContent).toBe("");
    expect(liveRegion.getAttribute("aria-live")).toBe("polite");

    act(() => clipboardInstances[0]?.fireSuccess());

    expect(screen.getByRole("status").textContent).toBe("Copied!");
  });

  it("uses the caller's copiedTooltip wording in the announcement", () => {
    render(
      <CopyToClipboard text="k" copiedTooltip="License key copied">
        <button>Copy</button>
      </CopyToClipboard>,
    );

    act(() => clipboardInstances[0]?.fireSuccess());

    expect(screen.getByRole("status").textContent).toBe("License key copied");
  });

  // The cleanup this asserts was silently discarded by useRunOnce, so every mounted
  // CopyToClipboard leaked its ClipboardJS instance for the lifetime of the page.
  it("destroys its ClipboardJS instance on unmount", () => {
    const { unmount } = render(
      <CopyToClipboard text="k">
        <button>Copy</button>
      </CopyToClipboard>,
    );

    const instance = clipboardInstances[0];
    expect(instance).toBeDefined();
    expect(instance?.destroy).not.toHaveBeenCalled();

    unmount();

    expect(instance?.destroy).toHaveBeenCalledTimes(1);
  });

  it("does not let a click on the copy affordance bubble to an enclosing handler", () => {
    const onOuterClick = vi.fn();
    render(
      <div onClick={onOuterClick}>
        <CopyToClipboard text="k">
          <button>Copy</button>
        </CopyToClipboard>
      </div>,
    );

    fireEvent.click(screen.getByRole("button", { name: "Copy" }));

    expect(onOuterClick).not.toHaveBeenCalled();
  });
});
