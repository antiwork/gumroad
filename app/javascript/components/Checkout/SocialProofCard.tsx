import * as React from "react";

import { trackSocialProofEvent } from "$app/data/social_proof";

import { NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";

interface BaseSocialProofCardProps {
  title: string;
  description: string;
  widgetId?: number; // Optional for preview mode
}

interface ProductImageProps extends BaseSocialProofCardProps {
  imageType: "product_thumbnail";
  imageUrl: string;
}

interface CustomImageProps extends BaseSocialProofCardProps {
  imageType: "custom_image";
  imageUrl: string;
}

interface IconImageProps extends BaseSocialProofCardProps {
  imageType: "icon";
  iconName: IconName;
  iconColor: string;
}

interface NoImageProps extends BaseSocialProofCardProps {
  imageType: "none";
}

interface ButtonCTAProps {
  ctaType: "button";
  ctaText: string;
  ctaUrl: string;
}

interface LinkCTAProps {
  ctaType: "link";
  ctaText: string;
  ctaUrl: string;
}

interface NoCTAProps {
  ctaType: "none";
}

type ImageTypeProps = ProductImageProps | CustomImageProps | IconImageProps | NoImageProps;
type CTATypeProps = ButtonCTAProps | LinkCTAProps | NoCTAProps;

export type SocialProofCardProps = ImageTypeProps &
  CTATypeProps & {
    ctaColor?: "primary" | "accent" | "black" | "success" | "danger" | "warning" | "info" | "filled";
    onClose?: () => void;
  };

export const SocialProofCard = (props: SocialProofCardProps) => {
  const { title, description, widgetId } = props;

  React.useEffect(() => {
    if (widgetId !== undefined) {
      void trackSocialProofEvent(widgetId, "impression");
    }
  }, [widgetId]);

  React.useEffect(
    () => () => {
      sessionStorage.removeItem("social_proof_widget_clicked");
    },
    [],
  );

  const handleClick = () => {
    if (widgetId !== undefined) {
      void trackSocialProofEvent(widgetId, "click");
      sessionStorage.setItem("social_proof_widget_clicked", widgetId.toString());
    }
  };

  const renderImage = () => {
    switch (props.imageType) {
      case "product_thumbnail":
      case "custom_image":
        return props.imageUrl ? (
          <img
            src={props.imageUrl}
            className="h-16 w-16 flex-shrink-0 rounded object-cover"
            alt="product thumbnail image"
          />
        ) : null;
      case "icon":
        return (
          <div
            className="grid h-16 w-16 flex-shrink-0 place-items-center rounded border"
            style={{ backgroundColor: `${props.iconColor}4D` }}
          >
            <Icon name={props.iconName} style={{ color: props.iconColor }} />
          </div>
        );
      case "none":
        return null;
    }
  };

  const renderCTA = () => {
    switch (props.ctaType) {
      case "button":
        return (
          <NavigationButton
            href={props.ctaUrl}
            color={props.ctaColor ?? "accent"}
            className="w-full"
            onClick={handleClick}
          >
            {props.ctaText}
          </NavigationButton>
        );
      case "link":
        return (
          <a href={props.ctaUrl} className="text-sm font-bold text-teal-400 no-underline" onClick={handleClick}>
            {props.ctaText}
          </a>
        );
      case "none":
        return null;
    }
  };

  return (
    <div className="bg-filled text-default fixed bottom-0 left-0 z-50 flex w-full max-w-none flex-col gap-3 rounded-none border-t p-4 shadow-lg sm:static sm:max-w-sm sm:rounded-lg sm:border sm:p-4 sm:shadow-md">
      <button
        type="button"
        className="absolute right-2 top-2 z-10 p-1 sm:right-2 sm:top-2"
        onClick={props.onClose}
        aria-label="Close"
      >
        <Icon name="x" className="text-current" />
      </button>
      <div className="flex items-center gap-3">
        {renderImage()}
        <div className="min-w-0 flex-1">
          <div className="text-base font-bold leading-tight sm:text-sm">{title}</div>
          <p className="text-sm leading-tight">{description}</p>
          {props.ctaType === "link" && renderCTA()}
        </div>
      </div>
      {props.ctaType === "button" && renderCTA()}
    </div>
  );
};
