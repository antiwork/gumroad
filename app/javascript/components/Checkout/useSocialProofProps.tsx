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

  const imageProps =
    image.id === "icon"
      ? {
          imageType: "icon",
          iconName: icon,
          iconColor,
        }
      : image.id === "product_thumbnail"
        ? productForThumbnail?.thumbnail_url
          ? {
              imageType: "product_thumbnail",
              imageUrl: productForThumbnail.thumbnail_url,
            }
          : {
              imageType: "none",
            }
        : image.id === "custom_image"
          ? {
              imageType: "custom_image",
              imageUrl: "/images/custom_image.jpg",
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
