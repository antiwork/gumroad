import * as React from "react";

import { Layout } from "$app/components/ProductEdit/Layout";
import { ReceiptPreview } from "$app/components/ProductEdit/ReceiptTab/ReceiptPreview";
import { useProductEditContext } from "$app/components/ProductEdit/state";

export const ReceiptTab = () => {
  const { product, updateProduct } = useProductEditContext();

  return (
    <Layout preview={<ReceiptPreview />}>
      <div className="squished">
        <form>
          <section className="p-4! md:p-8!">
            <div className="paragraphs">
              <h2>Customize your receipt</h2>
              <p>
                Add a custom message to your receipt emails and personalize the button text. This helps build trust
                and improve conversion by making the receipt feel more personal.
              </p>

              <fieldset>
                <label htmlFor="custom-receipt-text">Custom message</label>
                <textarea
                  id="custom-receipt-text"
                  placeholder="e.g., Thanks for your purchase! Check your email for access instructions."
                  value={product.custom_receipt_text ?? ""}
                  onChange={(e) => updateProduct({ custom_receipt_text: e.target.value })}
                  rows={5}
                  maxLength={product.custom_receipt_text_max_length}
                />
                <small>
                  {(product.custom_receipt_text ?? "").length} / {product.custom_receipt_text_max_length} characters
                </small>
                <p className="help">
                  This message will appear in the receipt email with a clear label showing it's from you.
                </p>
              </fieldset>

              <fieldset>
                <label htmlFor="custom-button-text">Button text</label>
                <input
                  id="custom-button-text"
                  type="text"
                  placeholder="View content"
                  value={product.custom_view_content_button_text ?? ""}
                  onChange={(e) => updateProduct({ custom_view_content_button_text: e.target.value })}
                  maxLength={product.custom_view_content_button_text_max_length}
                />
                <small>
                  {(product.custom_view_content_button_text ?? "").length} /{" "}
                  {product.custom_view_content_button_text_max_length} characters
                </small>
                <p className="help">
                  Customize the button text (e.g., "Join the Community", "Start Learning"). Leave blank for default
                  "View content".
                </p>
              </fieldset>
            </div>
          </section>
        </form>
      </div>
    </Layout>
  );
};
