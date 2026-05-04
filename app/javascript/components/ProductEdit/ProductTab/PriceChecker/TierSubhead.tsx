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
  const text =
    tier === "with_taxonomy" && taxonomyLabel
      ? `Based on ${matchCount} ${productTypeLabel} in ${taxonomyLabel}.`
      : `Based on ${matchCount} ${productTypeLabel} (broadened — set a category to refine).`;

  return <p className="text-xs text-muted">{text}</p>;
};
