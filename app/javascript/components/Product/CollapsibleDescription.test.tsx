// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { CollapsibleDescription } from "$app/components/Product/CollapsibleDescription";

// happy-dom has no layout engine, so ResizeObserver never fires and scrollHeight is always 0.
// Stub both: the observer invokes its callback immediately on observe(), and each test sets the
// scrollHeight the component measures.
let scrollHeight = 0;

class ImmediateResizeObserver {
  private readonly callback: ResizeObserverCallback;
  constructor(callback: ResizeObserverCallback) {
    this.callback = callback;
  }
  observe(this: ResizeObserver & ImmediateResizeObserver) {
    this.callback([], this);
  }
  unobserve() {}
  disconnect() {}
}

beforeEach(() => {
  vi.stubGlobal("ResizeObserver", ImmediateResizeObserver);
  Object.defineProperty(HTMLElement.prototype, "scrollHeight", {
    configurable: true,
    get: () => scrollHeight,
  });
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("CollapsibleDescription", () => {
  it("renders short descriptions without a toggle or clamping", () => {
    scrollHeight = 300;
    const { container } = render(
      <CollapsibleDescription>
        <p>Short description</p>
      </CollapsibleDescription>,
    );

    expect(screen.queryByRole("button")).toBeNull();
    expect(container.querySelector(".overflow-hidden")).toBeNull();
    expect(screen.getByText("Short description")).toBeTruthy();
  });

  it("collapses tall descriptions behind a Read more toggle while keeping the content in the DOM", () => {
    scrollHeight = 2000;
    const { container } = render(
      <CollapsibleDescription>
        <p>Very long description</p>
      </CollapsibleDescription>,
    );

    const toggle = screen.getByRole("button", { name: "Read more" });
    expect(toggle.getAttribute("aria-expanded")).toBe("false");
    expect(container.querySelector(".overflow-hidden")).not.toBeNull();
    // The collapse is CSS-only; the full content must stay in the DOM for SSR/SEO.
    expect(screen.getByText("Very long description")).toBeTruthy();
  });

  it("expands on Read more and collapses again on Show less", () => {
    scrollHeight = 2000;
    const { container } = render(
      <CollapsibleDescription>
        <p>Very long description</p>
      </CollapsibleDescription>,
    );

    fireEvent.click(screen.getByRole("button", { name: "Read more" }));
    const toggle = screen.getByRole("button", { name: "Show less" });
    expect(toggle.getAttribute("aria-expanded")).toBe("true");
    expect(container.querySelector(".overflow-hidden")).toBeNull();

    fireEvent.click(toggle);
    expect(screen.getByRole("button", { name: "Read more" })).toBeTruthy();
    expect(container.querySelector(".overflow-hidden")).not.toBeNull();
  });

  it("does not collapse descriptions only slightly taller than the collapsed height", () => {
    // Just above the 400px collapsed height but below the 520px threshold.
    scrollHeight = 450;
    render(
      <CollapsibleDescription>
        <p>Medium description</p>
      </CollapsibleDescription>,
    );

    expect(screen.queryByRole("button")).toBeNull();
  });
});
