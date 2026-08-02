// @vitest-environment happy-dom
import { act, cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { NodeVisibilityProvider, useNodeVisibility } from "$app/components/ProductEdit/ContentTab/useNodeVisibility";

type Instance = { root: Element | null; observed: Element[]; disconnected: boolean };

let instances: Instance[] = [];

class FakeIntersectionObserver {
  instance: Instance;

  constructor(_callback: IntersectionObserverCallback, options?: IntersectionObserverInit) {
    const root = options?.root;
    this.instance = { root: root instanceof Element ? root : null, observed: [], disconnected: false };
    instances.push(this.instance);
  }
  observe(element: Element) {
    this.instance.observed.push(element);
  }
  unobserve() {}
  disconnect() {
    this.instance.disconnected = true;
  }
}

// The editor scrolls the layout element only at `lg`; below it the document scrolls.
const Harness = ({ overflowY }: { overflowY: React.CSSProperties["overflowY"] }) => {
  const scrollRef = React.useRef<HTMLDivElement>(null);
  return (
    <div ref={scrollRef} style={{ overflowY }}>
      <NodeVisibilityProvider scrollRef={scrollRef}>
        <FileNode />
      </NodeVisibilityProvider>
    </div>
  );
};

const FileNode = () => {
  const { ref } = useNodeVisibility(82);
  return <div ref={ref} data-testid="file-node" />;
};

const latest = () => {
  const instance = instances.at(-1);
  if (!instance) throw new Error("expected an IntersectionObserver to have been constructed");
  return instance;
};

beforeEach(() => {
  instances = [];
  vi.stubGlobal("IntersectionObserver", FakeIntersectionObserver);
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("NodeVisibilityProvider", () => {
  it("observes against the layout element when that element is the scroll container", () => {
    const { container } = render(<Harness overflowY="auto" />);

    expect(latest().root).toBe(container.firstElementChild);
    expect(latest().observed).toContain(container.querySelector("[data-testid='file-node']"));
  });

  it("observes against the viewport when the layout element does not scroll", () => {
    render(<Harness overflowY="visible" />);

    // Rooting at a non-scrolling element makes target and root move together, so nodes below the
    // initial rootMargin never intersect and stay blank for the session.
    expect(latest().root).toBeNull();
  });

  it("rebuilds the observer and re-observes existing nodes when the layout starts scrolling", () => {
    const { container, rerender } = render(<Harness overflowY="visible" />);
    const node = container.querySelector("[data-testid='file-node']");
    expect(latest().root).toBeNull();
    const before = latest();

    rerender(<Harness overflowY="auto" />);
    act(() => {
      window.dispatchEvent(new Event("resize"));
    });

    expect(before.disconnected).toBe(true);
    expect(latest().root).toBe(container.firstElementChild);
    expect(latest().observed).toContain(node);
  });
});
