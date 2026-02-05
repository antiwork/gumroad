import * as React from "react";

import { request, assertResponseError } from "$app/utils/request";

import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";
import { useRunOnce } from "$app/components/useRunOnce";

export const ReceiptPreview = ({
  uniquePermalink,
  custom_receipt_text,
  custom_view_content_button_text,
}: {
  uniquePermalink: string;
  custom_receipt_text: string | null;
  custom_view_content_button_text: string | null;
}) => {
  const [receiptHtml, setReceiptHtml] = React.useState<string>("");

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
        accept: "html",
      });

      const html = await response.text();
      setReceiptHtml(html);
    } catch (error) {
      assertResponseError(error);
      setReceiptHtml("Error loading receipt preview");
    }
  }, [uniquePermalink, custom_receipt_text, custom_view_content_button_text]);

  const debouncedFetchReceiptPreview = useDebouncedCallback(() => void fetchReceiptPreview(), 300);

  useRunOnce(() => void fetchReceiptPreview());
  useOnChange(debouncedFetchReceiptPreview, [uniquePermalink, custom_receipt_text, custom_view_content_button_text]);

  return <div className="dark:[&_.wordmark_img]:invert" dangerouslySetInnerHTML={{ __html: receiptHtml }} />;
};
