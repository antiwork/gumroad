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
      case "product_thumbnail":
        return productForThumbnail?.thumbnail_url
          ? { imageType: "product_thumbnail", imageUrl: productForThumbnail.thumbnail_url }
          : { imageType: "none" };
      case "custom_image":
        return { imageType: "custom_image", imageUrl: "/images/custom_image.jpg" };
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
