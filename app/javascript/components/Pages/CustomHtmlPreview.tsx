import * as React from "react";
import typia from "typia";

import { request } from "$app/utils/request";

// The editor-pane half of the gumroad:products bridge (gumroad-private#1691). On the live
// storefront the trusted wrapper document answers these; here the dashboard does, so a page
// that awaits a catalogue slice renders in the preview instead of hanging on a promise that
// never settles.
//
// The framed document is the seller's own untrusted HTML, so this side is the boundary: the
// slice endpoint is derived server-side from the signed-in session, nothing in the message
// picks an account, and offset/limit are validated before they reach it. The sandbox has no
// allow-same-origin, so e.origin is "null" and e.source is the only usable check — same as
// the production wrapper.
type ProductsRequest = { type: "gumroad:products"; offset?: unknown; limit?: unknown; requestId?: unknown };
type ProductsSlice = {
  success: true;
  products: unknown[];
  products_total: number;
  prices: Record<string, unknown>;
  offset?: number;
  limit?: number;
};

const isIndex = (value: unknown): value is number => typia.is<number>(value) && Number.isInteger(value) && value >= 0;

export const CustomHtmlPreview = ({
  src,
  productsSrc,
  productsDefaultLimit,
  title,
  className,
}: {
  src: string;
  productsSrc: string;
  // What an omitted limit means, mirroring the live wrapper's MAX_ITEMS default. A preview that
  // instead forwarded "no limit" would fail the endpoint's own validation.
  productsDefaultLimit: number;
  title: string;
  className?: string;
}) => {
  const frameRef = React.useRef<HTMLIFrameElement>(null);
  // Bumped on every iframe load (including the first). e.source is the frame's WindowProxy,
  // which is navigation-stable in real browsers — capturing it does NOT identify the document
  // that sent the request, so a reply after reload would still land in the new document. This
  // generation is the only thing that actually changes on reload, so it's what gates the reply.
  const generationRef = React.useRef(0);

  React.useEffect(() => {
    const onMessage = (e: MessageEvent) => {
      const frame = frameRef.current;
      if (!frame || e.source !== frame.contentWindow) return;
      if (!typia.is<ProductsRequest>(e.data)) return;
      const message = e.data;

      const requestId = typia.is<string>(message.requestId) ? message.requestId : null;
      const requestGeneration = generationRef.current;
      const reply = (payload: Record<string, unknown>) => {
        // Frame reloaded since this request was received: the document that's listening now is
        // not the one that asked, and a reused request id would resolve its promise with stale
        // data. Drop the reply rather than deliver it to whatever document is there now.
        if (generationRef.current !== requestGeneration) return;
        frame.contentWindow?.postMessage({ ...payload, type: "gumroad:products:result", requestId }, "*");
      };

      const offset = message.offset;
      const limit = message.limit === undefined || message.limit === null ? productsDefaultLimit : message.limit;
      if (!isIndex(offset) || !isIndex(limit) || limit < 1) {
        reply({ success: false });
        return;
      }

      const url = new URL(productsSrc, window.location.origin);
      url.searchParams.set("offset", String(offset));
      url.searchParams.set("limit", String(limit));
      void (async () => {
        try {
          const response = await request({ method: "GET", accept: "json", url: url.toString() });
          if (!response.ok) {
            reply({ success: false });
            return;
          }
          const body: unknown = await response.json();
          if (!typia.is<ProductsSlice>(body)) {
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
  }, [productsSrc, productsDefaultLimit]);

  return (
    <iframe
      ref={frameRef}
      title={title}
      src={src}
      sandbox="allow-scripts"
      className={className}
      onLoad={() => (generationRef.current += 1)}
    />
  );
};
