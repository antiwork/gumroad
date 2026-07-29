// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { LandingPagePreview } from "$app/components/ProductEdit/LandingPagePreview";

// The preview embeds the seller's own custom HTML in a sandboxed iframe. That
// HTML is untrusted: it can post whatever it likes to the editor, so the editor
// is the boundary. These tests drive the same messages a page could send.
const STORE_HOSTNAMES = ["seller.gumroad.com", "store.example.com"];

let openSpy: ReturnType<typeof vi.fn>;

const renderPreview = () => {
  const result = render(<LandingPagePreview uniquePermalink="abc" storeHostnames={STORE_HOSTNAMES} />);
  const frame = result.container.querySelector("iframe");
  if (!frame) throw new Error("expected the preview iframe to render");
  return frame;
};

// Messages are only honoured when they come from the preview frame itself, so
// every test has to claim that window as the source.
const postFromFrame = (frame: HTMLIFrameElement, data: unknown) => {
  window.dispatchEvent(new MessageEvent("message", { data, source: frame.contentWindow }));
};

beforeEach(() => {
  openSpy = vi.fn();
  vi.stubGlobal("open", openSpy);
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("LandingPagePreview navigation messages", () => {
  it("opens a link to one of the seller's own hosts", () => {
    const frame = renderPreview();

    postFromFrame(frame, { type: "gumroad:navigate", url: "https://seller.gumroad.com/l/other-product" });

    expect(openSpy).toHaveBeenCalledWith("https://seller.gumroad.com/l/other-product", "_blank", "noopener");
  });

  it("opens a link to the seller's custom domain", () => {
    const frame = renderPreview();

    postFromFrame(frame, { type: "gumroad:navigate", url: "https://store.example.com/products" });

    expect(openSpy).toHaveBeenCalledWith("https://store.example.com/products", "_blank", "noopener");
  });

  it("ignores a destination on a host the seller does not control", () => {
    const frame = renderPreview();

    postFromFrame(frame, { type: "gumroad:navigate", url: "https://evil.example/phish" });

    expect(openSpy).not.toHaveBeenCalled();
  });

  it("ignores a shared Gumroad host the seller does not control", () => {
    const frame = renderPreview();

    postFromFrame(frame, { type: "gumroad:navigate", url: "https://gumroad.com/settings" });

    expect(openSpy).not.toHaveBeenCalled();
  });

  it("ignores a non-http(s) destination", () => {
    const frame = renderPreview();

    postFromFrame(frame, { type: "gumroad:navigate", url: "javascript:alert(1)" });

    expect(openSpy).not.toHaveBeenCalled();
  });

  it("ignores a navigation message that did not come from the preview frame", () => {
    renderPreview();

    window.dispatchEvent(
      new MessageEvent("message", {
        data: { type: "gumroad:navigate", url: "https://seller.gumroad.com/l/other-product" },
        source: window,
      }),
    );

    expect(openSpy).not.toHaveBeenCalled();
  });

  it("still opens checkout for the buy button", () => {
    const frame = renderPreview();

    postFromFrame(frame, { type: "gumroad:checkout", params: { quantity: 2 } });

    expect(openSpy).toHaveBeenCalledWith("/l/abc?quantity=2&wanted=true", "_blank", "noopener");
  });
});
