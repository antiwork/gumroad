import * as React from "react";
import { SocialProofWidgetData } from "$app/components/SocialProofWidget/types";
import { WidgetDisplay } from "$app/components/SocialProofWidget/WidgetDisplay";
import { Product } from "$app/components/Product";

type SocialProofWidgetsProps = {
  widgets: SocialProofWidgetData[];
  className?: string;
  displayMode?: "desktop" | "mobile";
  validate: () => boolean;
  checkoutUrl: string | null;
  product: Product;
};

export const SocialProofWidgets: React.FC<SocialProofWidgetsProps> = ({ 
  widgets, 
  className,
  displayMode = "desktop",
  validate,
  checkoutUrl,
  product
}) => {
  const [dismissedWidgets, setDismissedWidgets] = React.useState<Set<string>>(new Set());
  const [currentMobileIndex, setCurrentMobileIndex] = React.useState(0);

  console.log('Widgets received:', widgets);
  console.log('Product:', product);

  if (!widgets || widgets.length === 0) {
    return null;
  }

  const visibleWidgets = widgets.filter(widget => !dismissedWidgets.has(widget.id));

  if (visibleWidgets.length === 0) {
    return null;
  }

  const handleCtaClick = (widget: SocialProofWidgetData) => {
    console.log('click social proof widget')
    
    if (!checkoutUrl) {
      console.log('No checkout URL available');
      return;
    }

    if (!validate()) {
      console.log('not passing validation')
      return;
    }

    if (typeof window !== "undefined" && "gtag" in window) {
      const gtag = (window as { gtag: (...args: unknown[]) => void }).gtag;
      gtag("event", "social_proof_cta_click", {
        widget_id: widget.id,
        widget_name: widget.name,
        cta_type: widget.cta_type,
        location: displayMode === "mobile" ? "mobile_floating" : "desktop_inline",
      });
    }

    window.location.href = checkoutUrl;
  };

  const handleDismiss = (widgetId: string) => {
    setDismissedWidgets(prev => new Set([...prev, widgetId]));
    if (displayMode === "mobile") {
      const nextVisibleWidgets = visibleWidgets.filter(w => w.id !== widgetId);
      
      if (nextVisibleWidgets.length > 0) {
        if (currentMobileIndex >= nextVisibleWidgets.length) {
          setCurrentMobileIndex(0);
        }
      }
    }
  };

  // For mobile, show one widget at a time
  if (displayMode === "mobile") {
    const currentWidget = visibleWidgets[currentMobileIndex];
    if (!currentWidget) return null;

    return (
      <div className={className} style={{ position: "fixed", bottom: 0, left: 0, right: 0, zIndex: 1000 }}>
        <WidgetDisplay
          widget={currentWidget}
          displayMode="mobile"
          onCtaClick={() => handleCtaClick(currentWidget)}
          onClose={() => handleDismiss(currentWidget.id)}
        />
      </div>
    );
  }

  // For desktop, show all widgets
  return (
    <div className={className} style={{ display: "flex", flexDirection: "column", gap: "var(--spacer-4)", maxWidth: "600px", minWidth: "400px" }}>
      {visibleWidgets.map((widget) => (
        <WidgetDisplay
          key={widget.id}
          widget={widget}
          displayMode="desktop"
          onCtaClick={() => handleCtaClick(widget)}
          onClose={() => handleDismiss(widget.id)}
        />
      ))}
    </div>
  );
};