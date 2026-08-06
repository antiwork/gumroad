// @vitest-environment happy-dom
import { cleanup, render, waitFor } from "@testing-library/react";
import * as React from "react";
import typia from "typia";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { CustomHtmlPreview } from "$app/components/Pages/CustomHtmlPreview";

// The framed document is the seller's own untrusted HTML — it can post whatever it likes, so
// these drive the same messages a page could send and assert what the editor answers.
const mocks = vi.hoisted(() => ({ request: vi.fn() }));
vi.mock("$app/utils/request", () => ({ request: mocks.request }));

const PRODUCTS_PATH = "/pages/profile/products";
// Pages::ProfileData::MAX_ITEMS, threaded in as a prop.
const DEFAULT_LIMIT = 100;

const renderPreview = () => {
  const result = render(
    <CustomHtmlPreview
      title="Page preview"
      src="/pages/profile/preview"
      productsSrc={PRODUCTS_PATH}
      productsDefaultLimit={DEFAULT_LIMIT}
    />,
  );
  const frame = result.container.querySelector("iframe");
  if (!frame) throw new Error("expected the preview iframe to render");
  // happy-dom gives the frame a real contentWindow; spy on its postMessage to read the reply.
  const post = vi.fn();
  Object.defineProperty(frame.contentWindow, "postMessage", { value: post, configurable: true });
  return { frame, post };
};

const postFromFrame = (frame: HTMLIFrameElement, data: unknown) => {
  window.dispatchEvent(new MessageEvent("message", { data, source: frame.contentWindow }));
};

const jsonResponse = (body: unknown) => ({ ok: true, json: () => Promise.resolve(body) });

// The single URL the responder fetched, as a string the assertions can parse.
const requestedUrl = (): string => {
  const settings: unknown = mocks.request.mock.calls[0]?.[0];
  if (!typia.is<{ url: string }>(settings)) throw new Error("expected the responder to have fetched a slice");
  return settings.url;
};

beforeEach(() => {
  mocks.request.mockReset();
});

afterEach(() => {
  cleanup();
});

describe("CustomHtmlPreview products bridge", () => {
  it("resolves a slice request with the echoed request id", async () => {
    mocks.request.mockResolvedValue(
      jsonResponse({ success: true, products: [{ name: "Two" }], products_total: 3, prices: {}, offset: 1, limit: 1 }),
    );
    const { frame, post } = renderPreview();

    postFromFrame(frame, { type: "gumroad:products", offset: 1, limit: 1, requestId: "gumroad-products-1" });

    await waitFor(() =>
      expect(post).toHaveBeenCalledWith(
        {
          type: "gumroad:products:result",
          requestId: "gumroad-products-1",
          success: true,
          products: [{ name: "Two" }],
          productsTotal: 3,
          prices: {},
          offset: 1,
          limit: 1,
        },
        "*",
      ),
    );
    const url = new URL(requestedUrl(), "http://localhost");
    expect(url.pathname).toBe(PRODUCTS_PATH);
    expect(url.searchParams.get("offset")).toBe("1");
    expect(url.searchParams.get("limit")).toBe("1");
  });

  // The live wrapper defaults an omitted limit to MAX_ITEMS; the endpoint rejects a request
  // without one, so forwarding "no limit" would fail every offset-only page.
  it("defaults an omitted limit to the live bridge's MAX_ITEMS", async () => {
    mocks.request.mockResolvedValue(jsonResponse({ success: true, products: [], products_total: 0, prices: {} }));
    const { frame } = renderPreview();

    postFromFrame(frame, { type: "gumroad:products", offset: 0, requestId: "gumroad-products-1" });

    await waitFor(() => expect(mocks.request).toHaveBeenCalled());
    const url = new URL(requestedUrl(), "http://localhost");
    expect(url.searchParams.get("limit")).toBe(String(DEFAULT_LIMIT));
  });

  it("defaults a null limit the same way", async () => {
    mocks.request.mockResolvedValue(jsonResponse({ success: true, products: [], products_total: 0, prices: {} }));
    const { frame } = renderPreview();

    postFromFrame(frame, { type: "gumroad:products", offset: 0, limit: null, requestId: "gumroad-products-1" });

    await waitFor(() => expect(mocks.request).toHaveBeenCalled());
    const url = new URL(requestedUrl(), "http://localhost");
    expect(url.searchParams.get("limit")).toBe(String(DEFAULT_LIMIT));
  });

  it("rejects a non-integer or negative offset/limit without hitting the server", async () => {
    const { frame, post } = renderPreview();

    for (const bad of [
      { offset: -1, limit: 2 },
      { offset: 1.5, limit: 2 },
      { offset: "0", limit: 2 },
      { offset: 0, limit: 0 },
      { offset: 0, limit: -3 },
      { offset: 0, limit: "2" },
    ]) {
      postFromFrame(frame, { type: "gumroad:products", ...bad, requestId: "r" });
    }

    await waitFor(() => expect(post).toHaveBeenCalledTimes(6));
    for (const [payload] of post.mock.calls) expect(payload).toMatchObject({ success: false });
    expect(mocks.request).not.toHaveBeenCalled();
  });

  it("replies with a settled failure when the request fails, so the page never hangs", async () => {
    mocks.request.mockRejectedValue(new Error("network"));
    const { frame, post } = renderPreview();

    postFromFrame(frame, { type: "gumroad:products", offset: 0, limit: 1, requestId: "gumroad-products-1" });

    await waitFor(() =>
      expect(post).toHaveBeenCalledWith(
        { type: "gumroad:products:result", requestId: "gumroad-products-1", success: false },
        "*",
      ),
    );
  });

  it("replies with a failure when the endpoint answers success: false", async () => {
    mocks.request.mockResolvedValue(jsonResponse({ success: false }));
    const { frame, post } = renderPreview();

    postFromFrame(frame, { type: "gumroad:products", offset: 0, limit: 1, requestId: "r" });

    await waitFor(() => expect(post).toHaveBeenCalledWith(expect.objectContaining({ success: false }), "*"));
  });

  it("ignores messages that did not come from the preview frame", async () => {
    renderPreview();

    window.dispatchEvent(
      new MessageEvent("message", {
        data: { type: "gumroad:products", offset: 0, limit: 1, requestId: "r" },
        source: window,
      }),
    );

    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(mocks.request).not.toHaveBeenCalled();
  });

  it("replies to the window that sent the request, not whatever the iframe's contentWindow is by the time it resolves", async () => {
    let resolveRequest: (value: unknown) => void = () => undefined;
    mocks.request.mockReturnValue(new Promise((resolve) => (resolveRequest = resolve)));
    const { frame } = renderPreview();

    const originalSource = frame.contentWindow;
    const originalPost = vi.fn();
    if (originalSource)
      Object.defineProperty(originalSource, "postMessage", { value: originalPost, configurable: true });
    postFromFrame(frame, { type: "gumroad:products", offset: 0, limit: 1, requestId: "gumroad-products-1" });

    // Simulate a preview reload swapping in a new document before the in-flight request settles.
    const replacementPost = vi.fn();
    Object.defineProperty(frame, "contentWindow", { value: { postMessage: replacementPost }, configurable: true });

    resolveRequest(jsonResponse({ success: true, products: [], products_total: 0, prices: {} }));
    await waitFor(() => expect(originalPost).toHaveBeenCalled());
    expect(replacementPost).not.toHaveBeenCalled();
  });

  it("ignores messages of other types", async () => {
    const { frame } = renderPreview();

    postFromFrame(frame, { type: "gumroad:follow", email: "x@example.com" });

    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(mocks.request).not.toHaveBeenCalled();
  });
});
