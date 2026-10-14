import * as React from "react";

import { lazyWithRetry } from "$app/utils/lazy_chunk";

import { FallbackOnError } from "$app/components/FallbackOnError";
import type { PublicFile } from "$app/components/Product";

// Tiptap, ProseMirror, and highlight.js stay off the product page's blocking path. Until they
// arrive, and if they never do, buyers read the stored HTML without its custom embeds.
const Description = lazyWithRetry(
  () => import("$app/components/Product/Description"),
  (module) => module.Description,
);

export const LazyDescription = ({ html, publicFiles }: { html: string | null; publicFiles: PublicFile[] }) => {
  // dir="auto" gives the description a base direction from its first strong character; per-block
  // direction for mixed-language content is handled by the unicode-bidi: plaintext rule in
  // _rich_text.scss (gumroad-private#1244).
  const fallback = <div className="rich-text" dir="auto" dangerouslySetInnerHTML={{ __html: html ?? "" }} />;

  return (
    <FallbackOnError fallback={fallback}>
      <React.Suspense fallback={fallback}>
        <Description html={html} publicFiles={publicFiles} fallback={fallback} />
      </React.Suspense>
    </FallbackOnError>
  );
};
