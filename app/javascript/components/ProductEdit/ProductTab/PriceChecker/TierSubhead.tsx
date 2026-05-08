import * as React from "react";

export const TierSubhead = ({
  matchCount,
  tier,
  taxonomyLabel,
  productTypeLabel,
}: {
  matchCount: number;
  tier: "with_taxonomy" | "broadened";
  taxonomyLabel: string | null;
  productTypeLabel: string;
}) => {
  const text = (() => {
    if (tier === "with_taxonomy" && taxonomyLabel) {
      return `Based on ${matchCount} ${productTypeLabel} in ${taxonomyLabel}.`;
    }
    if (tier === "with_taxonomy") {
      return `Based on ${matchCount} ${productTypeLabel} on Gumroad.`;
    }
    return `Based on ${matchCount} ${productTypeLabel} (broadened — set a category to refine).`;
  })();

  return <small className="block text-muted">{text}</small>;
};
