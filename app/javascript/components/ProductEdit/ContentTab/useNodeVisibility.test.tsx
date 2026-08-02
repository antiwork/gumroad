// @vitest-environment happy-dom
import { act, cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { NodeVisibilityProvider, useNodeVisibility } from "$app/components/ProductEdit/ContentTab/useNodeVisibility";

// The harness sets overflow-y inline, so the computed value never comes from a media query the way
// it does in the app. What is under test is the branch on that value, not Tailwind's breakpoints.

type Instance = {
  root: Element | null;
  rootMargin: string | undefined;
  observed: Element[];
  unobserved: Element[];
  disconnected: boolean;
  emit: (entries: { target: Element; isIntersecting: boolean }[]) => void;
};

let instances: Instance[] = [];

// The hook reads only `target` and `isIntersecting` off each entry, so the fake hands the callback
// those two fields rather than building whole IntersectionObserverEntry objects.
type PartialEntry = { target: Element; isIntersecting: boolean };

class FakeIntersectionObserver {
  instance: Instance;

  constructor(callback: (entries: PartialEntry[]) => void, options?: IntersectionObserverInit) {
    const root = options?.root;
    this.instance = {
      root: root instanceof Element ? root : null,
      rootMargin: options?.rootMargin,
      observed: [],
      unobserved: [],
      disconnected: false,
      emit: (entries) => callback(entries),
    };
    instances.push(this.instance);
  }
  observe(element: Element) {
    this.instance.observed.push(element);
  }
  unobserve(element: Element) {
    this.instance.unobserved.push(element);
  }
  disconnect() {
    this.instance.disconnected = true;
  }
}

// The editor scrolls the layout element only at `lg`; below it the document scrolls.
const Harness = ({ overflowY, nodeCount = 1 }: { overflowY: React.CSSProperties["overflowY"]; nodeCount?: number }) => {
  const scrollRef = React.useRef<HTMLDivElement>(null);
  return (
    <div ref={scrollRef} style={{ overflowY }}>
      <NodeVisibilityProvider scrollRef={scrollRef}>
        {Array.from({ length: nodeCount }, (_, i) => (
          <FileNode key={i} index={i} />
        ))}
      </NodeVisibilityProvider>
    </div>
  );
};

const FileNode = ({ index }: { index: number }) => {
  const { ref, visible } = useNodeVisibility(82);
  return <div ref={ref} data-testid={`file-node-${index}`} data-visible={visible} />;
};

const latest = () => {
  const instance = instances.at(-1);
  if (!instance) throw new Error("expected an IntersectionObserver to have been constructed");
  return instance;
};

const nodes = (container: HTMLElement) => [...container.querySelectorAll("[data-testid^='file-node-']")];

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
    expect(latest().observed).toContain(nodes(container)[0]);
  });

  it("observes against the viewport when the layout element does not scroll", () => {
    render(<Harness overflowY="visible" />);

    // Rooting at a non-scrolling element makes target and root move together, so nodes below the
    // initial rootMargin never intersect and stay blank for the session.
    expect(latest().root).toBeNull();
  });

  it("keeps the prefetch window that makes virtualization invisible to the user", () => {
    render(<Harness overflowY="auto" />);

    expect(latest().rootMargin).toBe("1000px");
  });

  it("observes nodes that mount after the observer exists", () => {
    // The editor renders no node views on the provider's first commit, so this — not the
    // re-observe loop — is the path every real file embed registers through.
    const { container, rerender } = render(<Harness overflowY="auto" nodeCount={1} />);
    rerender(<Harness overflowY="auto" nodeCount={2} />);

    expect(latest().observed).toEqual(nodes(container));
  });

  it("renders a node once it intersects, and stops observing it when it unmounts", () => {
    const { container, rerender } = render(<Harness overflowY="auto" />);
    const node = nodes(container)[0];
    if (!node) throw new Error("expected a file node");
    expect(node.getAttribute("data-visible")).toBe("false");

    act(() => latest().emit([{ target: node, isIntersecting: true }]));
    expect(node.getAttribute("data-visible")).toBe("true");

    const observer = latest();
    rerender(<Harness overflowY="auto" nodeCount={0} />);
    expect(observer.unobserved).toContain(node);
  });

  it("rebuilds the observer and re-observes existing nodes when the layout starts scrolling", () => {
    const { container, rerender } = render(<Harness overflowY="visible" />);
    const node = nodes(container)[0];
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
