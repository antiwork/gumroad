import * as React from "react";

import { DefinitionList } from "$app/components/ui/DefinitionList";

export type FeeInfo = {
  summary: string;
  items: { label: string; value: string }[];
};

export const FeeInfoDetails = ({ feeInfo }: { feeInfo: FeeInfo }) => (
  <div className="grid gap-2">
    <p>{feeInfo.summary}</p>
    {feeInfo.items.length > 0 ? (
      <DefinitionList className="gap-y-1">
        {feeInfo.items.map((item) => (
          <React.Fragment key={item.label}>
            <dt className="text-muted">{item.label}</dt>
            <dd>{item.value}</dd>
          </React.Fragment>
        ))}
      </DefinitionList>
    ) : null}
  </div>
);
