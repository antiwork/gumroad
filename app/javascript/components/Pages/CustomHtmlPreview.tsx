import * as React from "react";

import { request } from "$app/utils/request";

// The editor-pane half of the gumroad:products bridge (gumroad-private#1691). On the live
// storefront the trusted wrapper document answers these; here the dashboard does, so a page
// that builds cards from catalogue slices renders in the preview instead of hanging on a
// promise that never settles.
//
// The framed document is the seller's own untrusted HTML, so this side is the boundary: the
// slice endpoint is the seller's own (`src` is derived from the signed-in session server-side),
// nothing in the message picks an account, and offset/limit are validated as non-negative
// integers before they reach it. The sandbox has no allow-same-origin, so e.origin is "null"
// and e.source is the only usable check — same as the production wrapper.
type ProductsResponse = {
  success?: unknown;
  products?: unknown;
  products_total?: unknown;
  prices?: unknown;
  offset?: unknown;
  limit?: unknown;
};

export const CustomHtmlPreview = ({
  src,
  productsSrc,
  title,
  className,
}: {
  src: string;
  productsSrc: string;
  title: string;
  className?: string;
}) => {
  const frameRef = React.useRef<HTMLIFrameElement>(null);

  React.useEffect(() => {
    const onMessage = (e: MessageEvent) => {
      const frame = frameRef.current;
      if (!frame || e.source !== frame.contentWindow) return;
      const data: unknown = e.data;
      if (typeof data !== "object" || data === null) return;
      const message = data as { type?: unknown; offset?: unknown; limit?: unknown; requestId?: unknown };
      if (message.type !== "gumroad:products") return;

      const requestId = typeof message.requestId === "string" ? message.requestId : null;
      const reply = (payload: Record<string, unknown>) => {
        frame.contentWindow?.postMessage({ ...payload, type: "gumroad:products:result", requestId }, "*");
      };

      const isIndex = (value: unknown): value is number =>
        typeof value === "number" && Number.isInteger(value) && value >= 0;
      const offset = message.offset;
      const limit = message.limit === undefined || message.limit === null ? undefined : message.limit;
      if (!isIndex(offset) || (limit !== undefined && (!isIndex(limit) || limit < 1))) {
        reply({ success: false });
        return;
      }

      const url = new URL(productsSrc, window.location.origin);
      url.searchParams.set("offset", String(offset));
      if (limit !== undefined) url.searchParams.set("limit", String(limit));
      void (async () => {
        try {
          const response = await request({ method: "GET", accept: "json", url: url.toString() });
          if (!response.ok) {
            reply({ success: false });
            return;
          }
          const body = (await response.json()) as ProductsResponse;
          if (body.success !== true) {
            reply({ success: false });
            return;
          }
          reply({
            success: true,
            products: body.products,
            productsTotal: body.products_total,
            prices: body.prices,
            offset: body.offset,
            limit: body.limit,
          });
        } catch {
          reply({ success: false });
        }
      })();
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [productsSrc]);

  return (
    <iframe ref={frameRef} title={title} src={src} sandbox="allow-scripts" className={className} />
  );
};
