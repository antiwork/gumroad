// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PageHeader } from "$app/components/ui/PageHeader";
import { usePageHeaderOffset } from "$app/components/ui/usePageHeaderOffset";

const Harness = () => {
  const headerRef = usePageHeaderOffset();

  return (
    <div className="scroller" data-testid="scroller">
      <PageHeader ref={headerRef} className="sticky top-0 z-10 bg-body" title="Untitled">
        <span>Product</span>
      </PageHeader>
      <div role="toolbar" style={{ top: "var(--page-header-height, 0px)" }}>
        Insert
      </div>
    </div>
  );
};

// happy-dom has no layout engine, so the header height is whatever the test says it is.
const offsetHeightDescriptor = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "offsetHeight");
const setHeaderHeight = (height: number) =>
  Object.defineProperty(HTMLElement.prototype, "offsetHeight", { configurable: true, get: () => height });

const scroller = () => {
  const element = document.querySelector<HTMLElement>('[data-testid="scroller"]');
  if (!element) throw new Error("the scroller was not rendered");
  return element;
};
const publishedHeight = () => scroller().style.getPropertyValue("--page-header-height");

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  if (offsetHeightDescriptor) Object.defineProperty(HTMLElement.prototype, "offsetHeight", offsetHeightDescriptor);
  vi.restoreAllMocks();
});

describe("usePageHeaderOffset", () => {
  it("publishes the header height on the scroll region the toolbar offsets itself by", () => {
    setHeaderHeight(72);

    const { getByRole } = render(<Harness />);

    // The toolbar resolves the variable from an ancestor, so the height has to land on the
    // scroller — the header's parent — rather than on the header itself. (What the toolbar does
    // with the value is a computed-style concern happy-dom cannot round-trip; the local QA
    // screenshots cover the rendered offset.)
    expect(publishedHeight()).toBe("72px");
    expect(scroller().contains(getByRole("toolbar"))).toBe(true);
  });

  it("re-measures when the header wraps to a different height", () => {
    setHeaderHeight(72);
    const resizeCallbacks: ResizeObserverCallback[] = [];
    class StubObserver implements ResizeObserver {
      observe() {}
      unobserve() {}
      disconnect() {}
    }
    class CapturingResizeObserver extends StubObserver {
      constructor(callback: ResizeObserverCallback) {
        super();
        resizeCallbacks.push(callback);
      }
    }
    const noopObserver = new StubObserver();
    vi.stubGlobal("ResizeObserver", CapturingResizeObserver);

    render(<Harness />);
    expect(publishedHeight()).toBe("72px");

    setHeaderHeight(132);
    act(() => resizeCallbacks.forEach((callback) => callback([], noopObserver)));

    expect(publishedHeight()).toBe("132px");
  });

  it("clears the published height when the page unmounts", () => {
    setHeaderHeight(72);

    const { unmount } = render(<Harness />);
    const region = scroller();
    expect(region.style.getPropertyValue("--page-header-height")).toBe("72px");

    unmount();

    expect(region.style.getPropertyValue("--page-header-height")).toBe("");
  });

  it("publishes when the page renders its header after the first mount", () => {
    setHeaderHeight(96);

    const Deferred = () => {
      const [showHeader, setShowHeader] = React.useState(false);
      const headerRef = usePageHeaderOffset();

      return (
        <div data-testid="scroller">
          {showHeader ? <PageHeader ref={headerRef} className="sticky top-0 z-10 bg-body" title="Untitled" /> : null}
          <button onClick={() => setShowHeader(true)}>show the header</button>
        </div>
      );
    };

    // Pages/Edit and Settings/Profile/Show each render their header in only one of several
    // branches, so the height has to be measured when the header appears, not only at mount.
    render(<Deferred />);
    expect(publishedHeight()).toBe("");

    fireEvent.click(screen.getByRole("button", { name: "show the header" }));

    expect(publishedHeight()).toBe("96px");
  });
});
