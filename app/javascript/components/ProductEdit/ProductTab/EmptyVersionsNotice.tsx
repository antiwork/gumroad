import * as React from "react";

import { type ProductNativeType } from "$app/parsers/product";

import { useProductEditContext } from "$app/components/ProductEdit/state";
import { Alert } from "$app/components/ui/Alert";

// For these types a version's deliverable is its own files or rich content, so
// a version with neither hands the buyer an empty download page. Physical
// variants (size, colour) and service products deliver another way, so they are
// deliberately out of scope.
const FILE_DELIVERING_TYPES: ProductNativeType[] = ["digital", "course", "ebook", "newsletter", "podcast", "audiobook"];

export const EmptyVersionsNotice = () => {
  const { product } = useProductEditContext();

  if (!FILE_DELIVERING_TYPES.includes(product.native_type)) return null;
  // Shared content means every version delivers the product-level content, so a
  // version's own empty list is not a gap.
  if (product.has_same_rich_content_for_all_variants) return null;

  const emptyVersions = product.variants.filter((variant) => variant.rich_content.length === 0 && !variant.has_files);
  if (emptyVersions.length === 0) return null;

  const names = emptyVersions.map((variant) => `“${variant.name || "Untitled"}”`).join(", ");

  return (
    <Alert role="status" variant="warning">
      {emptyVersions.length === 1
        ? `${names} has no files or content. Buyers who purchase it get an empty download page — add content for this version in the Content tab.`
        : `${names} have no files or content. Buyers who purchase them get an empty download page — add content for each version in the Content tab.`}
    </Alert>
  );
};
