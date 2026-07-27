// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CopyToClipboard } from "$app/components/CopyToClipboard";

// ClipboardJS attaches its own document-level listeners and is not the thing under test here — what
// matters is only whether CopyToClipboard destroys the instance it created. So stand in a fake whose
// destroy() we can assert on.
const destroy = vi.fn();
const clipboardConstructor = vi.fn();

vi.mock("clipboard", () => ({
  default: class FakeClipboardJS {
    constructor(...args: unknown[]) {
      clipboardConstructor(...args);
    }
    on() {
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
});
