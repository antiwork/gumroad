import { cast } from "ts-safe-cast";

import type { SocialProofCardProps } from "./SocialProofCard";

interface PreviewInput {
  titleText: string;
  description: string;
  ctaText: string;
  ctaType: "button" | "link" | "none";
  image: {
    id: "product" | "custom" | "icon" | "none";
    label: "Product image" | "Custom image" | "Icon" | "None";
  };
  icon: string;
  iconColor: string;
}

export const useSocialProofCardPropsFromPreview = ({
  titleText,
  description,
  ctaText,
  ctaType,
  image,
  icon,
  iconColor,
}: PreviewInput): SocialProofCardProps => {
  const imageProps =
    image.id === "icon"
      ? {
          imageType: "icon",
          iconName: icon,
          iconColor,
        }
      : image.id === "product" || image.id === "custom"
        ? {
            imageType: image.id,
            imageUrl: `/images/${image.id}.jpg`,
          }
        : {
            imageType: "none",
          };

  const ctaProps =
    ctaType === "button"
      ? {
          ctaType: "button",
          ctaText,
          ctaUrl: "#",
        }
      : ctaType === "link"
        ? {
            ctaType: "link",
            ctaText,
            ctaUrl: "#",
          }
        : {
            ctaType: "none",
          };

  return cast({
    title: titleText,
    description,
    ...imageProps,
    ...ctaProps,
  });
};
