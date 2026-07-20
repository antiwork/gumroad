import DOMPurify from "dompurify";

// Video players like Vimeo remove their fullscreen button entirely when the embedding
// iframe doesn't grant fullscreen permission (the page inside the frame sees
// `document.fullscreenEnabled === false`). Embed HTML stored in rich content — for
// example the iframely proxy iframes used for unlisted Vimeo links — often ships with
// an `allow` list that lacks fullscreen and no `allowfullscreen` attribute, so buyers
// can't fullscreen videos in product descriptions. Granting the permission here, at
// sanitize time, fixes every already-stored embed without requiring sellers to
// re-insert their videos. This mirrors what cover-carousel embeds
// (components/Product/Covers/Embed.tsx) already do by hardcoding `allowFullScreen`.
let fullscreenHookRegistered = false;
const registerFullscreenHook = () => {
  if (fullscreenHookRegistered) return;
  fullscreenHookRegistered = true;
  DOMPurify.addHook("afterSanitizeAttributes", (node) => {
    if (node.tagName !== "IFRAME") return;
    node.setAttribute("allowfullscreen", "");
    const allow = node.getAttribute("allow")?.trim() ?? "";
    if (!/\bfullscreen\b/u.test(allow)) {
      node.setAttribute(
        "allow",
        allow === "" ? "fullscreen *;" : `${allow.endsWith(";") ? allow : `${allow};`} fullscreen *;`,
      );
    }
  });
};

/**
 * Sanitizes an HTML string using DOMPurify.
 * Allows 'iframe' tags and attributes needed for embedded media, and ensures every
 * iframe carries fullscreen permission (see the hook above for why).
 *
 * @param dirtyHtml The HTML string to sanitize.
 * @returns The sanitized HTML string.
 * @throws Error if called in a server-side environment
 */
export const sanitizeHtml = (dirtyHtml: string): string => {
  if (typeof window === "undefined") {
    throw new Error("sanitizeHtml can only be used in client-side environments");
  }

  registerFullscreenHook();

  return DOMPurify.sanitize(dirtyHtml, {
    ADD_TAGS: ["iframe"],
    ADD_ATTR: ["src", "allow", "allowfullscreen", "width", "height", "title", "sandbox"],
  });
};
