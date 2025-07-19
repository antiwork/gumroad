import { cast } from "ts-safe-cast";

import type { SocialProofCardProps } from "./SocialProofCard";

interface PreviewInput {
  titleText: string;
  description: string;
  ctaText: string;
  ctaType: "button" | "link" | "none";
  image: {
    id: "product_thumbnail" | "custom_image" | "icon" | "none";
    label: "Product image" | "Custom image" | "Icon" | "None";
  };
  icon: string;
  iconColor: string;
  selectedProducts?: {
    id: string;
    name: string;
    url: string;
    is_tiered_membership: boolean;
    archived: boolean;
    thumbnail_url?: string | null;
  }[];
  universal?: boolean;
  allProducts?: {
    id: string;
    name: string;
    url: string;
    is_tiered_membership: boolean;
    archived: boolean;
    thumbnail_url?: string | null;
  }[];
  customImageUrl?: string | null;
  currentProductThumbnailUrl?: string | null;
}

export const useSocialProofCardPropsFromPreview = ({
  titleText,
  description,
  ctaText,
  ctaType,
  image,
  icon,
  iconColor,
  selectedProducts,
  universal,
  allProducts,
  customImageUrl,
  currentProductThumbnailUrl,
}: PreviewInput): SocialProofCardProps => {
  // Get the best product to use for thumbnail
  const getProductForThumbnail = () => {
    if (selectedProducts && selectedProducts.length > 0) {
      return selectedProducts[0];
    }
    if (universal && allProducts && allProducts.length > 0) {
      return allProducts.find((p) => !p.archived) || allProducts[0];
    }
    return null;
  };

  const productForThumbnail = getProductForThumbnail();

  const getImageProps = () => {
    switch (image.id) {
      case "icon":
        return { imageType: "icon", iconName: icon, iconColor };
      case "product_thumbnail": {
        // For product_thumbnail, prioritize currentProductThumbnailUrl (for live display)
        // fallback to selected product's thumbnail_url (for preview)
        const thumbnailUrl = currentProductThumbnailUrl || productForThumbnail?.thumbnail_url;
        return thumbnailUrl ? { imageType: "product_thumbnail", imageUrl: thumbnailUrl } : { imageType: "none" };
      }
      case "custom_image":
        return customImageUrl ? { imageType: "custom_image", imageUrl: customImageUrl } : { imageType: "none" };
      default:
        return { imageType: "none" };
    }
  };

  const imageProps = getImageProps();
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
