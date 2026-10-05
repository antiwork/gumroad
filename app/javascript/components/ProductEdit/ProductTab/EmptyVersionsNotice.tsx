import * as React from "react";

import { type ProductNativeType } from "$app/parsers/product";

import { useProductEditContext } from "$app/components/ProductEdit/state";
import { Alert } from "$app/components/ui/Alert";

// For these types a version's deliverable is its own files or rich content, so
// a version with neither hands the buyer an empty download page. Physical
// variants (size, colour) and service products deliver another way, so they are
// deliberately out of scope.
const FILE_DELIVERING_TYPES: ProductNativeType[] = ["digital", "course", "ebook", "newsletter", "podcast", "audiobook"];

// Mirrors RichContent#has_editor_content? on the server: a page is content when
// it has a title, or a body node that renders something. An empty paragraph or
// heading does not — and that bare paragraph is the page "Add page" creates, so
// a version holding only those still delivers nothing.
const nodeHasContent = (node: unknown): boolean => {
  if (!node || typeof node !== "object") return false;
  const { type, text, content } = node as { type?: string; text?: string; content?: unknown };
  if (typeof text === "string" && text.length > 0) return true;
  if (Array.isArray(content)) return content.some(nodeHasContent);
  return type !== "paragraph" && type !== "heading";
};

const pageHasContent = (page: { title: string | null; description: object }) => {
  if (page.title) return true;
  const content = (page.description as { content?: unknown }).content;
  return Array.isArray(content) && content.some(nodeHasContent);
};

export const EmptyVersionsNotice = () => {
  const { product } = useProductEditContext();

  if (!FILE_DELIVERING_TYPES.includes(product.native_type)) return null;
  // Shared content means every version delivers the product-level content, so a
  // version's own empty list is not a gap.
  if (product.has_same_rich_content_for_all_variants) return null;

  const emptyVersions = product.variants.filter((variant) => !variant.has_files && !variant.rich_content.some(pageHasContent));
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
