import * as React from "react";
import { SocialProofWidgetData } from "$app/components/SocialProofWidget/types";
import { WidgetDisplay } from "$app/components/SocialProofWidget/WidgetDisplay";
import { trackWidgetImpression, trackWidgetClick, trackWidgetDismiss } from "$app/data/social_proof_widgets";
import { trackElementInViewport } from "$app/utils/viewport_tracking";

type SocialProofWidgetsProps = {
  widgets: SocialProofWidgetData[];
  className?: string;
  displayMode?: "desktop" | "mobile";
  validate: () => boolean;
  checkoutUrl: string | null;
};

export const SocialProofWidgets: React.FC<SocialProofWidgetsProps> = ({ 
  widgets, 
  className,
  displayMode = "desktop",
  validate,
  checkoutUrl,
}) => {
  const [dismissedWidgets, setDismissedWidgets] = React.useState<Set<string>>(new Set());
  const [currentMobileIndex, setCurrentMobileIndex] = React.useState(0);
  const trackedImpressionsRef = React.useRef<Set<string>>(new Set());
  const observersRef = React.useRef<{ [key: string]: IntersectionObserver }>({});

  const handleWidgetImpression = (widgetId: string) => {
    if (!trackedImpressionsRef.current.has(widgetId)) {
      trackedImpressionsRef.current.add(widgetId);
      trackWidgetImpression(widgetId);
    }
  };

  React.useEffect(() => {
    if (displayMode === "desktop") {
      Object.values(observersRef.current).forEach(observer => observer.disconnect());
      observersRef.current = {};

      widgets.forEach(widget => {
        const element = document.querySelector(`[data-widget-id="${widget.id}"]`);
        if (element) {
          const newObserver = trackElementInViewport(element as HTMLElement, () => {
            handleWidgetImpression(widget.id);
          });
          
          if (newObserver) {
            observersRef.current[widget.id] = newObserver;
          }
        }
      });
    }
    return () => {
      Object.values(observersRef.current).forEach(observer => observer.disconnect());
      observersRef.current = {}
    }
  }, [widgets, displayMode])

  React.useEffect(() => {
    if (displayMode === "mobile" && widgets[currentMobileIndex]) {
      const currentWidget = widgets[currentMobileIndex];
      if (!trackedImpressionsRef.current.has(currentWidget.id)) {
        handleWidgetImpression(currentWidget.id);
      }
    }
  }, [displayMode, currentMobileIndex, widgets]);

  if (!widgets || widgets.length === 0) {
    return null;
  }

  const visibleWidgets = widgets.filter(widget => !dismissedWidgets.has(widget.id));

  if (visibleWidgets.length === 0) {
    return null;
  }

  const handleCtaClick = (widget: SocialProofWidgetData) => {
    if (!checkoutUrl) return;
    if (!validate()) return;

    trackWidgetClick(widget.id);

    const url = new URL(checkoutUrl);
    url.searchParams.set('widget_id', widget.id);

    if (typeof window !== "undefined" && "gtag" in window) {
      const gtag = (window as { gtag: (...args: unknown[]) => void }).gtag;
      gtag("event", "social_proof_cta_click", {
        widget_id: widget.id,
        widget_name: widget.name,
        cta_type: widget.cta_type,
        location: displayMode === "mobile" ? "mobile_floating" : "desktop_inline",
      });
    }

    window.location.href = url.toString();
  };

  const handleDismiss = (widgetId: string) => {
    setDismissedWidgets(prev => new Set([...prev, widgetId]));
    trackWidgetDismiss(widgetId);
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
          key={currentWidget.id}
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