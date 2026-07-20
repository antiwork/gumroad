// @vitest-environment happy-dom
// Stop happy-dom from actually fetching the iframe src URLs in the fixtures below —
// without this the test log fills with NetworkError noise from aborted requests.
// @vitest-environment-options {"settings": {"disableIframePageLoading": true, "disableJavaScriptFileLoading": true, "disableCSSFileLoading": true}}
import { describe, expect, it } from "vitest";

import { sanitizeHtml } from "$app/utils/sanitize";

// Extracts the single iframe from sanitized output so assertions can inspect attributes
// directly instead of string-matching serialized HTML (attribute order isn't guaranteed).
const sanitizeToIframe = (html: string) => {
  const container = document.createElement("div");
  container.innerHTML = sanitizeHtml(html);
  const iframe = container.querySelector("iframe");
  if (!iframe) throw new Error("expected sanitized output to contain an iframe");
  return iframe;
};

describe("sanitizeHtml", () => {
  it("strips script tags", () => {
    expect(sanitizeHtml('<p>hello</p><script>alert("xss")</script>')).toBe("<p>hello</p>");
  });

  it("preserves iframes with their embed attributes", () => {
    const iframe = sanitizeToIframe(
      '<iframe src="https://player.vimeo.com/video/123" width="640" height="360" title="My video"></iframe>',
    );
    expect(iframe.getAttribute("src")).toBe("https://player.vimeo.com/video/123");
    expect(iframe.getAttribute("width")).toBe("640");
    expect(iframe.getAttribute("height")).toBe("360");
    expect(iframe.getAttribute("title")).toBe("My video");
  });

  it("adds fullscreen permission to iframes that lack it entirely", () => {
    // The shape iframely returns for unlisted Vimeo links: no allowfullscreen, and an
    // allow list without fullscreen — the case where Vimeo hides its fullscreen button.
    const iframe = sanitizeToIframe(
      '<iframe src="https://iframely.net/api/iframe?url=x" allow="encrypted-media *;"></iframe>',
    );
    expect(iframe.hasAttribute("allowfullscreen")).toBe(true);
    expect(iframe.getAttribute("allow")).toBe("encrypted-media *; fullscreen *;");
  });

  it("adds fullscreen permission to iframes with no allow attribute", () => {
    const iframe = sanitizeToIframe('<iframe src="https://example.com/embed"></iframe>');
    expect(iframe.hasAttribute("allowfullscreen")).toBe(true);
    expect(iframe.getAttribute("allow")).toBe("fullscreen *;");
  });

  it("appends a separator when the existing allow list doesn't end with one", () => {
    const iframe = sanitizeToIframe('<iframe src="https://example.com/embed" allow="autoplay"></iframe>');
    expect(iframe.getAttribute("allow")).toBe("autoplay; fullscreen *;");
  });

  it("leaves iframes that already grant fullscreen unchanged", () => {
    const iframe = sanitizeToIframe(
      '<iframe src="https://player.vimeo.com/video/123" allow="autoplay; fullscreen; picture-in-picture" allowfullscreen></iframe>',
    );
    expect(iframe.hasAttribute("allowfullscreen")).toBe(true);
    expect(iframe.getAttribute("allow")).toBe("autoplay; fullscreen; picture-in-picture");
  });

  it("does not touch non-iframe elements", () => {
    const sanitized = sanitizeHtml("<p>plain text</p>");
    expect(sanitized).toBe("<p>plain text</p>");
    expect(sanitized).not.toContain("allowfullscreen");
  });
});
