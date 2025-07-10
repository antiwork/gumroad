import * as React from "react";
import { Preview } from "$app/components/Preview";
import { WidgetDisplay } from "./WidgetDisplay";
import { SocialProofWidgetData } from "./types";
import { Product } from "$app/components/Checkout/cartState";

interface WidgetPreviewProps {
  product: Product;
}

export const WidgetPreview: React.FC<WidgetPreviewProps> = ({ product }) => {
  const widget = product.social_proof_widgets?.[0]
  if (!widget) {
    return null;
  }

  const previewWidget: SocialProofWidgetData = {
    id: widget.id,
    name: widget.name,
    title: widget.title,
    description: widget.description,
    cta_text: widget.cta_text,
    cta_type: widget.cta_type,
    image_type: widget.image_type,
    icon_name: widget.icon_name ?? null,
    icon_color: widget.icon_color ?? null,
    image_url: widget.image_type === 'product_thumbnail' ? (product.thumbnail_url ?? null) : (widget.image_url ?? null),
  };

  return (
    <aside aria-label="Preview">
      <header>
        <h2>Preview</h2>
      </header>
      <Preview scaleFactor={0.4} style={{ 
        border: "var(--border)",
        backgroundColor: "var(--body-bg)", 
        borderRadius: "var(--border-radius-2)",
        padding: "var(--spacer-4)",
        display: "flex",
        justifyContent: "center",
        alignItems: "center"
      }}>
        <WidgetDisplay 
          widget={previewWidget}
          className="preview-widget"
          onCtaClick={() => {}} // intentionally empty because its a preview component
        />
      </Preview>
    </aside>
  );
};
