export function manualChunks(id: string) {
  // Before the node_modules early-return: this helper is not always under node_modules, and
  // leaving it unpinned lets rollup park it in a lazy chunk every page then statically imports.
  if (id.includes("vite/preload-helper")) return "vendor";

  if (!id.includes("node_modules")) return;

  // Rich-text editor (Tiptap + ProseMirror) — self-contained, ~97KB gzip
  if (id.includes("/@tiptap/") || id.includes("/prosemirror-")) {
    return "vendor-editor";
  }

  // Charts (Recharts + D3) — self-contained, ~82KB gzip
  if (id.includes("/recharts/") || id.includes("/d3-") || id.includes("/recharts-scale/") || id.includes("/victory-")) {
    return "vendor-charts";
  }

  // Braintree / PayPal — self-contained, ~41KB gzip
  if (id.includes("/braintree-web/") || id.includes("/@paypal/")) {
    return "vendor-payments";
  }

  // EPUB reader — loaded only from the buyer's EPUB read page
  if (
    id.includes("/epubjs/") ||
    id.includes("/jszip/") ||
    id.includes("/localforage/") ||
    id.includes("/@xmldom/xmldom/") ||
    id.includes("/event-emitter/") ||
    id.includes("/marks-pane/") ||
    id.includes("/path-webpack/")
  ) {
    return "vendor-epub";
  }

  // PDF.js worker — huge (2.3MB), loaded lazily on demand
  if (id.includes("/pdfjs-dist/")) {
    return "vendor-pdf";
  }

  // Everything else from node_modules → single vendor chunk.
  // This includes React, Inertia, Radix, Stripe, date-fns, lodash, etc.
  // Keeping them together avoids circular chunk warnings from the deep
  // cross-imports between React and its ecosystem packages.
  return "vendor";
}
