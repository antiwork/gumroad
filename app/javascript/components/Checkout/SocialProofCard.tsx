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
  imageType: "product";
  imageUrl: string;
}

interface CustomImageProps extends BaseSocialProofCardProps {
  imageType: "custom";
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
  };

export const SocialProofCard = (props: SocialProofCardProps) => {
  const { title, description, widgetId } = props;

  // Track impression when component mounts (only for real widgets, not preview)
  React.useEffect(() => {
    if (widgetId !== undefined) {
      void trackSocialProofEvent(widgetId, "impression");
    }
  }, [widgetId]);

  // Track click events (only for real widgets, not preview)
  const handleClick = () => {
    if (widgetId !== undefined) {
      void trackSocialProofEvent(widgetId, "click");
    }
  };

  const renderImage = () => {
    switch (props.imageType) {
      case "product":
      case "custom":
        return <img src={props.imageUrl} />;
      case "icon":
        return (
          <div
            className="grid h-[72px] w-[72px] place-items-center rounded border"
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
    <div
      className="bg-filled relative flex w-full max-w-sm flex-col gap-4 rounded-lg border p-4"
      style={{ boxShadow: "var(--box-shadow-1, 4px 4px 16px 0px #00000029)" }}
    >
      <div className="">
        <div className="flex gap-3">
          {renderImage()}
          <div className="flex-1">
            <div className="text-sm font-bold">{title}</div>
            <p className="text-sm">{description}</p>
            {props.ctaType === "link" && renderCTA()}
          </div>
        </div>
        <Icon name="x" className="absolute right-2 top-1 text-current" />
      </div>
      {props.ctaType === "button" && renderCTA()}
    </div>
  );
};
