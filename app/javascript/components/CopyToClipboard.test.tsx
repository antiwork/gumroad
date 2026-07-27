// @vitest-environment happy-dom
import { act, cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CopyToClipboard } from "$app/components/CopyToClipboard";

// ClipboardJS attaches its own document-level listeners and is not the thing under test here — what
// matters is only whether CopyToClipboard destroys the instance it created. So stand in a fake whose
// destroy() we can assert on.
const destroy = vi.fn();
const clipboardConstructor = vi.fn();
// Captures the "success" handlers CopyToClipboard registers, so a test can fire a copy without a
// real clipboard or selection (neither of which happy-dom provides).
const successHandlers: ((event: { clearSelection: () => void }) => void)[] = [];
const fireCopySuccess = () => successHandlers.forEach((h) => h({ clearSelection: () => {} }));

vi.mock("clipboard", () => ({
  default: class FakeClipboardJS {
    constructor(...args: unknown[]) {
      clipboardConstructor(...args);
    }
    on(event: string, handler: (e: { clearSelection: () => void }) => void) {
      if (event === "success") successHandlers.push(handler);
      return this;
    }
    destroy() {
      destroy();
    }
  },
}));

// WithTooltip wraps its child in extra span elements to position the tooltip. Those wrappers are
// irrelevant to the copy behaviour under test and would add noise to the DOM assertions, so render
// the child on its own.
vi.mock("$app/components/WithTooltip", () => ({
  WithTooltip: ({ children }: { children: React.ReactNode }) => children,
}));

afterEach(() => {
  cleanup();
  destroy.mockClear();
  clipboardConstructor.mockClear();
  successHandlers.length = 0;
  // One test spies on the EventTarget prototype methods, which would otherwise leak into the rest
  // of the suite.
  vi.restoreAllMocks();
});

describe("CopyToClipboard", () => {
  it("destroys its ClipboardJS instance when it unmounts", () => {
    // Regression test: the setup used to live in useRunOnce, which ignores a returned cleanup
    // function, so the instance was created and then never torn down for the life of the page.
    const { unmount } = render(
      <CopyToClipboard text="a-license-key">
        <button>Copy</button>
      </CopyToClipboard>,
    );

    expect(clipboardConstructor).toHaveBeenCalledTimes(1);
    expect(destroy).not.toHaveBeenCalled();

    unmount();

    expect(destroy).toHaveBeenCalledTimes(1);
  });

  it("removes its mouseleave listener when it unmounts", () => {
    // The mouseleave listener resets the tooltip back to "Copy to Clipboard". It was registered on
    // the wrapper node and never removed, so it outlived the component. Assert on the actual
    // add/remove pair rather than on a React warning: React no longer warns about setting state on
    // an unmounted component, so a test relying on that warning would pass either way.
    const added: (EventListenerOrEventListenerObject | null)[] = [];
    const removed: (EventListenerOrEventListenerObject | null)[] = [];
    const add = HTMLElement.prototype.addEventListener;
    const remove = HTMLElement.prototype.removeEventListener;
    vi.spyOn(HTMLElement.prototype, "addEventListener").mockImplementation(function (
      this: HTMLElement,
      type,
      listener,
      options,
    ) {
      if (type === "mouseleave") added.push(listener);
      return add.call(this, type, listener, options);
    });
    vi.spyOn(HTMLElement.prototype, "removeEventListener").mockImplementation(function (
      this: HTMLElement,
      type,
      listener,
      options,
    ) {
      if (type === "mouseleave") removed.push(listener);
      return remove.call(this, type, listener, options);
    });

    const { unmount } = render(
      <CopyToClipboard text="a-license-key">
        <button>Copy</button>
      </CopyToClipboard>,
    );

    expect(added).toHaveLength(1);
    expect(removed).toHaveLength(0);

    unmount();

    // Same function reference, otherwise removeEventListener is a no-op and the listener stays.
    expect(removed).toEqual(added);
  });

  it("does not rebuild the ClipboardJS instance when the copied text changes", () => {
    // The text is read through a ref precisely so that a re-render with new text does not tear down
    // and rebuild the clipboard binding.
    const { rerender } = render(
      <CopyToClipboard text="first">
        <button>Copy</button>
      </CopyToClipboard>,
    );

    rerender(
      <CopyToClipboard text="second">
        <button>Copy</button>
      </CopyToClipboard>,
    );

    expect(clipboardConstructor).toHaveBeenCalledTimes(1);
    expect(destroy).not.toHaveBeenCalled();
  });

  // Sighted users learn the copy worked from the tooltip flipping to copiedTooltip. That text
  // reaches assistive tech through aria-describedby, and changing already-referenced description
  // text is not an announced event, so screen-reader users got no confirmation at all.
  it("announces the copy through a live region once a copy succeeds", () => {
    render(
      <CopyToClipboard text="secret-key" copiedTooltip="Copied!">
        <button>Copy</button>
      </CopyToClipboard>,
    );

    const liveRegion = screen.getByRole("status");
    expect(liveRegion.getAttribute("aria-live")).toBe("polite");
    // Must stay visually hidden: without sr-only this span becomes a real second child of every
    // tooltip wrapper in the app, so "Copied!" would render visibly next to every copy affordance.
    expect(liveRegion.className).toContain("sr-only");
    // Empty on render, or every copy affordance on the page announces itself on load.
    expect(liveRegion.textContent).toBe("");

    act(() => fireCopySuccess());

    expect(screen.getByRole("status").textContent).toBe("Copied!");
  });

  it("announces the caller's own copiedTooltip wording", () => {
    render(
      <CopyToClipboard text="k" copiedTooltip="License key copied">
        <button>Copy</button>
      </CopyToClipboard>,
    );

    act(() => fireCopySuccess());

    expect(screen.getByRole("status").textContent).toBe("License key copied");
  });
});
