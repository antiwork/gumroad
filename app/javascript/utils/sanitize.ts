import DOMPurify from "dompurify";

/**
 * Sanitizes an HTML string using DOMPurify.
 * Allows 'iframe' tags and attributes needed for embedded media.
 *
 * @param dirtyHtml The HTML string to sanitize.
 * @returns The sanitized HTML string.
 * @throws Error if called in a server-side environment
 */
export const sanitizeHtml = (dirtyHtml: string): string => {
  if (typeof window === "undefined") {
    throw new Error("sanitizeHtml can only be used in client-side environments");
  }

  return DOMPurify.sanitize(dirtyHtml, {
    ADD_TAGS: ["iframe"],
    ADD_ATTR: ["src", "allow", "width", "height", "title", "sandbox"],
  });
};
