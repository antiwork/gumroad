import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { type AnalyticsReferrerTotals } from "$app/components/Analytics";
import { Button } from "$app/components/Button";
import { useClientSortingTableDriver } from "$app/components/useSortingTableDriver";

const ROWS_PER_PAGE = 10;

export const ReferrersTable = ({ data }: { data: AnalyticsReferrerTotals }) => {
  const tableData = React.useMemo(
    () =>
      Object.entries(data).map(([referrer, { sales, views, totals }]) => ({
        referrer,
        sales,
        views,
        totals,
        conversion: Math.min(sales / views, 1),
      })),
    [data],
  );

  const { items, thProps } = useClientSortingTableDriver(tableData, {
    key: "totals",
    direction: "desc",
  });

  const [maxRowsShown, setMaxRowsShown] = React.useState(ROWS_PER_PAGE);

  React.useEffect(() => {
    setMaxRowsShown(ROWS_PER_PAGE);
  }, [data]);

  return (
    <section className="paragraphs">
      <table>
        <caption>
          <a href="/help/article/74-the-analytics-dashboard" target="_blank" rel="noreferrer">
            Referrer
          </a>
        </caption>
        <thead>
          <tr>
            <th>Source</th>
            <th {...thProps("views")}>Views</th>
            <th {...thProps("sales")}>Sales</th>
            <th {...thProps("conversion")}>Conversion</th>
            <th {...thProps("totals")}>Total</th>
          </tr>
        </thead>
        <tbody>
          {items.slice(0, maxRowsShown).map(({ referrer, sales, views, totals, conversion }) => (
            <tr key={referrer} data-total={totals}>
              <td data-label="Source">{referrer === "direct" ? "Direct, email, IM" : referrer}</td>
              <td data-label="Views">{views}</td>
              <td data-label="Sales">{sales}</td>
              <td data-label="Conversion">{`${(conversion * 100).toFixed(1).replace(".0", "")}%`}</td>
              <td data-label="Total">
                {formatPriceCentsWithCurrencySymbol("usd", totals, { symbolFormat: "short", noCentsIfWhole: true })}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {items.length > maxRowsShown && (
        <Button onClick={() => setMaxRowsShown(maxRowsShown + ROWS_PER_PAGE)} className="flex">
          Show more
        </Button>
      )}
      {items.length ? null : <div className="input">Nothing yet</div>}
    </section>
  );
};
