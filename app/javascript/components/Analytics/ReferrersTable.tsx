import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { type AnalyticsReferrerTotals } from "$app/components/Analytics";
import { Button } from "$app/components/Button";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
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
    <section className="flex flex-col gap-4">
      <Table>
        <TableCaption>
          <a href="/help/article/74-the-analytics-dashboard" target="_blank" rel="noreferrer">
            Referrer
          </a>
        </TableCaption>
        <TableHeader>
          <TableRow>
            <TableHead>Source</TableHead>
            <TableHead {...thProps("views")}>Views</TableHead>
            <TableHead {...thProps("sales")}>Sales</TableHead>
            <TableHead {...thProps("conversion")}>Conversion</TableHead>
            <TableHead {...thProps("totals")}>Total</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {items.slice(0, maxRowsShown).map(({ referrer, sales, views, totals, conversion }) => (
            <TableRow key={referrer}>
              <TableCell>{referrer === "direct" ? "Direct, email, IM" : referrer}</TableCell>
              <TableCell>{views}</TableCell>
              <TableCell>{sales}</TableCell>
              <TableCell>{`${(conversion * 100).toFixed(1).replace(".0", "")}%`}</TableCell>
              <TableCell>
                {formatPriceCentsWithCurrencySymbol("usd", totals, { symbolFormat: "short", noCentsIfWhole: true })}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
      {items.length > maxRowsShown && (
        <Button onClick={() => setMaxRowsShown(maxRowsShown + ROWS_PER_PAGE)} className="flex">
          Show more
        </Button>
      )}
      {items.length ? null : <div className="input">Nothing yet</div>}
    </section>
  );
};
