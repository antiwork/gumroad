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

// WithTooltip renders its child through a portal-ish wrapper that needs more page chrome than this
// test has; the copy behaviour does not depend on it, so render the child directly.
vi.mock("$app/components/WithTooltip", () => ({
  WithTooltip: ({ children }: { children: React.ReactNode }) => children,
}));

afterEach(() => {
  cleanup();
  destroy.mockClear();
  clipboardConstructor.mockClear();
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

  it("stops resetting its status once it has unmounted", () => {
    // The mouseleave listener was added to a node the component no longer owns after unmount. If it
    // outlives the component, firing the event calls setState on an unmounted component.
    const { unmount, container } = render(
      <CopyToClipboard text="a-license-key">
        <button>Copy</button>
      </CopyToClipboard>,
    );

    const target = container.querySelector("span");
    expect(target).not.toBeNull();

    unmount();

    // Would warn about updating an unmounted component if the listener were still attached.
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    target?.dispatchEvent(new Event("mouseleave"));
    expect(errors).not.toHaveBeenCalled();
    errors.mockRestore();
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
