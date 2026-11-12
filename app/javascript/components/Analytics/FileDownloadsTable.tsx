import * as React from "react";

import { type AnalyticsFileDownloads } from "$app/data/analytics";

import { Button } from "$app/components/Button";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useClientSortingTableDriver } from "$app/components/useSortingTableDriver";

const ROWS_PER_PAGE = 10;

// `files` is null when the counts could not be loaded for this range.
export const FileDownloadsTable = ({
  files,
  selectedProducts,
}: {
  files: AnalyticsFileDownloads[] | null;
  selectedProducts: string[];
}) => {
  const tableData = React.useMemo(
    () =>
      (files ?? [])
        .filter((file) => selectedProducts.includes(file.product_permalink))
        .map((file) => ({ ...file, name: file.deleted ? `${file.name} (deleted)` : file.name })),
    [files, selectedProducts],
  );

  const { items, thProps } = useClientSortingTableDriver(tableData, { key: "downloads", direction: "desc" });

  const [maxRowsShown, setMaxRowsShown] = React.useState(ROWS_PER_PAGE);

  React.useEffect(() => {
    setMaxRowsShown(ROWS_PER_PAGE);
  }, [tableData]);

  return (
    <section>
      <Table>
        <TableCaption>Downloads</TableCaption>
        <TableHeader>
          <TableRow>
            <TableHead {...thProps("name")}>File</TableHead>
            <TableHead {...thProps("product_name")}>Product</TableHead>
            <TableHead {...thProps("downloads")}>Downloads</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {items.length ? (
            items.slice(0, maxRowsShown).map(({ id, name, product_name, downloads }) => (
              <TableRow key={id}>
                <TableCell>{name}</TableCell>
                <TableCell>{product_name}</TableCell>
                <TableCell>{downloads}</TableCell>
              </TableRow>
            ))
          ) : (
            <TableRow>
              <TableCell colSpan={3}>{files ? "Nothing yet" : "We couldn't load downloads for this range."}</TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>
      {items.length > maxRowsShown ? (
        <Button onClick={() => setMaxRowsShown(maxRowsShown + ROWS_PER_PAGE)} className="mt-4 flex">
          Show more
        </Button>
      ) : null}
    </section>
  );
};
