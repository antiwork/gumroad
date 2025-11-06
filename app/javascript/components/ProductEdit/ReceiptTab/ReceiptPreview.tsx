import * as React from "react";

import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useProductEditContext } from "$app/components/ProductEdit/state";

export const ReceiptPreview = () => {
  const { product } = useProductEditContext();
  const currentSeller = useCurrentSeller();

  if (!currentSeller) return null;

  const buttonText = (product.custom_view_content_button_text || "").trim() || "View content";
  const customMessage = (product.custom_receipt_text || "").trim();

  return (
    <div className="paragraphs" style={{ padding: "var(--spacer-6)" }}>
      <h3>Receipt Preview</h3>
      <div
        style={{
          border: "1px solid var(--border-color)",
          borderRadius: "var(--border-radius-2)",
          padding: "var(--spacer-6)",
          backgroundColor: "var(--body-bg)",
          fontFamily: "system-ui, -apple-system, sans-serif",
        }}
      >
        {/* Product Info */}
        <div style={{ marginBottom: "var(--spacer-4)" }}>
          <div style={{ display: "flex", alignItems: "center", gap: "var(--spacer-3)", marginBottom: "var(--spacer-3)" }}>
            {currentSeller.avatarUrl && (
              <img
                src={currentSeller.avatarUrl}
                alt={currentSeller.name || "Seller"}
                style={{
                  width: "40px",
                  height: "40px",
                  borderRadius: "50%",
                  objectFit: "cover",
                }}
              />
            )}
            <div>
              <strong>{currentSeller.name || currentSeller.email}</strong>
            </div>
          </div>
          <h4 style={{ margin: "var(--spacer-2) 0" }}>{product.name || "Product Name"}</h4>
        </div>

        {/* Custom Message */}
        {customMessage && (
          <div
            style={{
              margin: "var(--spacer-4) 0",
              padding: "var(--spacer-4)",
              backgroundColor: "#f9f9f9",
              borderLeft: "3px solid #ddd",
            }}
          >
            <p
              style={{
                margin: "0 0 var(--spacer-2)",
                fontSize: "12px",
                color: "#666",
                fontWeight: "bold",
              }}
            >
              Message from creator:
            </p>
            <p style={{ margin: 0, whiteSpace: "pre-wrap" }}>{customMessage}</p>
          </div>
        )}

        {/* Download Button */}
        <div style={{ marginTop: "var(--spacer-4)" }}>
          <button
            type="button"
            className="button primary"
            disabled
            style={{
              width: "100%",
              padding: "var(--spacer-3) var(--spacer-4)",
              cursor: "not-allowed",
            }}
          >
            {buttonText}
          </button>
        </div>

        {/* Product Details */}
        <div style={{ marginTop: "var(--spacer-4)", fontSize: "14px", color: "#666" }}>
          <div style={{ display: "flex", justifyContent: "space-between", padding: "var(--spacer-2) 0" }}>
            <span>Product price</span>
            <span>$XX.XX</span>
          </div>
        </div>

        {/* Footer */}
        <div
          style={{
            marginTop: "var(--spacer-6)",
            paddingTop: "var(--spacer-4)",
            borderTop: "1px solid var(--border-color)",
            textAlign: "center",
            fontSize: "12px",
            color: "#999",
          }}
        >
          <p style={{ margin: "var(--spacer-2) 0" }}>Powered by Gumroad</p>
        </div>
      </div>
    </div>
  );
};
