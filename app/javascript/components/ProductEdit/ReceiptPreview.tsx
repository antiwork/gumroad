import * as React from "react";

import { request, assertResponseError } from "$app/utils/request";

import { useProductEditContext } from "$app/components/ProductEdit/state";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";
import { useRunOnce } from "$app/components/useRunOnce";

// The receipt preview endpoint renders the REAL mailer template server-side and returns the
// subject alongside the body HTML. Both come from the same Rails response so the email-style
// chrome (Subject line) can never disagree with the rendered receipt below it — computing the
// subject client-side from unsaved form state while the body reflected saved server state let
// the two drift apart.
export const useReceiptPreview = () => {
  const {
    uniquePermalink,
    product: { custom_receipt_text, custom_view_content_button_text },
  } = useProductEditContext();
  const [preview, setPreview] = React.useState<{ subject: string | null; html: string }>({
    subject: null,
    html: "",
  });

  const fetchReceiptPreview = React.useCallback(async () => {
    try {
      const url = Routes.internal_product_receipt_preview_path(uniquePermalink, {
        params: {
          custom_receipt_text,
          custom_view_content_button_text,
        },
      });

      const response = await request({
        method: "GET",
        url,
        accept: "json",
      });

      const data: unknown = await response.json();
      if (
        response.ok &&
        typeof data === "object" &&
        data !== null &&
        "subject" in data &&
        typeof data.subject === "string" &&
        "html" in data &&
        typeof data.html === "string"
      ) {
        setPreview({ subject: data.subject, html: data.html });
      } else {
        setPreview({ subject: null, html: "Error loading receipt preview" });
      }
    } catch (error) {
      assertResponseError(error);
      setPreview({ subject: null, html: "Error loading receipt preview" });
    }
  }, [uniquePermalink, custom_receipt_text, custom_view_content_button_text]);

  const debouncedFetchReceiptPreview = useDebouncedCallback(() => void fetchReceiptPreview(), 300);

  useRunOnce(() => void fetchReceiptPreview());
  useOnChange(debouncedFetchReceiptPreview, [uniquePermalink, custom_receipt_text, custom_view_content_button_text]);

  return preview;
};

export const ReceiptPreview = ({ html }: { html: string }) => (
  <div className="dark:[&_.wordmark_img]:invert" dangerouslySetInnerHTML={{ __html: html }} />
);
