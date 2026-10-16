import * as React from "react";

import { Card, CardContent } from "$app/components/ui/Card";

export type FeeInfo = {
  summary: string;
  items: { label: string; value: string }[];
};

export const FeeInfoDetails = ({ feeInfo }: { feeInfo: FeeInfo }) => (
  <div className="grid gap-3">
    <p>{feeInfo.summary}</p>
    {feeInfo.items.length > 0 ? (
      <Card asChild>
        <dl>
          {feeInfo.items.map((item) => (
            <CardContent key={item.label} className="gap-x-4 gap-y-1">
              {/* Stacked at every width: the card's width varies by page, so with any breakpoint one long value wraps alone. */}
              <dt className="basis-full font-bold">{item.label}</dt>
              <dd>{item.value}</dd>
            </CardContent>
          ))}
        </dl>
      </Card>
    ) : null}
  </div>
);
