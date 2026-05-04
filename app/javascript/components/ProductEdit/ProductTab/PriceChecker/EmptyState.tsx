import * as React from "react";

import { Checklist } from "./Checklist";

export const EmptyState = ({
  matchCount,
  productTypeLabel,
  productNativeType,
  productName,
  productDescription,
  taxonomyId,
}: {
  matchCount: number;
  productTypeLabel: string;
  productNativeType: string | null | undefined;
  productName: string;
  productDescription: string;
  taxonomyId: string | null;
}) => (
  <div className="grid gap-3 rounded border border-dashed border-border bg-background p-4 text-sm">
    <div className="font-medium text-foreground">Not enough comparable products yet</div>
    <div className="text-muted">
      We found {matchCount} similar {productTypeLabel} on Gumroad — that&apos;s not enough for a reliable distribution.
      Filling in the missing fields below may improve match quality next time you check.
    </div>
    <Checklist
      productNativeType={productNativeType}
      productName={productName}
      productDescription={productDescription}
      taxonomyId={taxonomyId}
      productTypeLabel={productTypeLabel}
    />
  </div>
);
