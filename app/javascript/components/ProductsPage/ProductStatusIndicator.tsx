import { Icon } from "$app/components/Icons";

type ProductStatus = "unpublished" | "preorder" | "published";

interface ProductStatusIndicatorProps {
  status: ProductStatus;
}

export const ProductStatusIndicator = ({ status }: ProductStatusIndicatorProps) => {
  switch (status) {
    case "unpublished":
      return (
        <>
          <Icon name="circle" /> Unpublished
        </>
      );
    case "preorder":
      return (
        <>
          <Icon name="circle" /> Pre-order
        </>
      );
    case "published":
      return (
        <>
          <Icon name="circle-fill" /> Published
        </>
      );
  }
};