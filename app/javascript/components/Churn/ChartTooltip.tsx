import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

type DataPoint = {
  date: string;
  dateFormatted: string;
  churnRate: number;
  cancellations: number;
  revenueLost: number;
  label: string;
};

const ChartTooltip = ({ data }: { data: DataPoint }) => (
  <>
    <div>
      <strong>{data.churnRate.toFixed(1)}%</strong> churn
    </div>
    <div>
      <strong>{data.cancellations}</strong> {data.cancellations === 1 ? "cancellation" : "cancellations"}
    </div>
    <div>
      <strong>
        {formatPriceCentsWithCurrencySymbol("usd", data.revenueLost, {
          symbolFormat: "short",
          noCentsIfWhole: true,
        })}
      </strong>{" "}
      revenue lost
    </div>
    <time className="block font-bold">{data.dateFormatted}</time>
  </>
);

export default ChartTooltip;
