import cx from "classnames";
import * as React from "react";

import { Icon } from "$app/components/Icons";
import { SocialProofWidgetData } from "./types";

type WidgetDisplayProps = {
  widget: SocialProofWidgetData;
  className?: string;
  onCtaClick?: () => void;
  onClose?: () => void;
  displayMode?: "desktop" | "mobile";
}

export const WidgetDisplay: React.FC<WidgetDisplayProps> = ({
  widget,
  className,
  onCtaClick,
  onClose,
  displayMode = "desktop",
}) => {
  const handleCtaClick = () => {
    onCtaClick?.();
  };

  const handleClose = () => {
    onClose?.();
  };

  const renderImage = () => {
    if (widget.image_type?.startsWith("icon_") && widget.icon_name) {
      return (
        <div style={{ 
          width: "var(--spacer-8)", 
          height: "var(--spacer-8)", 
          flexShrink: 0, 
          borderRadius: "var(--border-radius-1)", 
          overflow: "hidden", 
          backgroundColor: "var(--body-bg)", 
          display: "flex", 
          alignItems: "center", 
          justifyContent: "center" 
        }}>
          <Icon 
            name={widget.icon_name as IconName} 
            style={{ 
              width: "100%", 
              height: "100%",
              color: widget.icon_color || "currentColor" // Use the icon color if provided
            }} 
          />
        </div>
      );
    }

    if (widget.image_url) {
      return (
        <div style={{ width: "var(--spacer-8)", height: "var(--spacer-8)", flexShrink: 0, borderRadius: "var(--border-radius-1)", overflow: "hidden" }}>
          <img src={widget.image_url} alt={widget.title} style={{ width: "100%", height: "100%", objectFit: "cover" }} />
        </div>
      );
    }

    return null;
  };

  const renderCtaButton = () => {
    if (widget.cta_type === "none") {
      return null;
    }
  
    if (widget.cta_type === "link") {
      return (
        <a
          href="#"
          onClick={(e) => {
            e.preventDefault();
            handleCtaClick();
          }}
          className="link"
          style={{ textAlign: "center", display: "block" }}
        >
          {widget.cta_text}
        </a>
      );
    }
  
    return (
      <button 
        onClick={handleCtaClick} 
        className="button accent"
        style={{ 
          width: "calc(100% - var(--spacer-8))", 
          margin: "0 auto",
          display: "block" 
        }}
      >
        {widget.cta_text}
      </button>
    );
  };

  const isMobile = displayMode === "mobile";

  return (
    <div 
      className={cx("card", className)}
      style={{
        ...(isMobile && {
          borderRadius: 0,
          borderTop: "solid var(--border-width) rgb(var(--primary))",
          borderLeft: "none",
          borderRight: "none",
          borderBottom: "none",
          width: "100%",
          margin: 0,
        }),
        position: "relative",
        display: "flex",
        flexDirection: "column",
        gap: "var(--spacer-4)",
      }}
    >
      <button 
        onClick={handleClose} 
        className="button"
        aria-label="Close"
        style={{
          position: "absolute",
          top: "var(--spacer-2)",
          right: "var(--spacer-2)",
          background: "none",
          border: "none",
          fontSize: "var(--big-icon-size)",
          cursor: "pointer",
          opacity: 0.5,
          padding: "var(--spacer-2)",
          zIndex: 1,
        }}
        onMouseEnter={(e) => {
          e.currentTarget.style.opacity = "1";
        }}
        onMouseLeave={(e) => {
          e.currentTarget.style.opacity = "0.5";
        }}
      >
        <Icon name="x" />
      </button>

      <div style={{ display: "flex", alignItems: "flex-start", gap: "var(--spacer-4)" }}>
        {renderImage()}

        <div style={{ flex: 1 }}>
          <h4 style={{ fontWeight: "bold", marginBottom: "var(--spacer-2)", color: "rgb(var(--color))" }}>
            {widget.title}
          </h4>
          <p style={{ fontSize: "var(--font-size-1)", lineHeight: 1.4, color: "rgb(var(--color))", margin: 0 }}>
            {widget.description}
          </p>
        </div>
      </div>

      {renderCtaButton()}
    </div>
  );
};
