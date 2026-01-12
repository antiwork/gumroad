import { orderBy } from "lodash-es";
import * as React from "react";

import { TableHead } from "$app/components/ui/Table";

type Direction = "asc" | "desc";
export type Sort<Key> = { key: Key; direction: Direction };

export const useClientSortingTableDriver = <Item>(
  items: readonly Item[],
  defaultSort?: { key: keyof Item; direction: Direction },
): { items: readonly Item[]; thProps: (key: keyof Item) => React.ComponentPropsWithoutRef<"th"> } => {
  const [sort, setSort] = React.useState<Sort<keyof Item> | null>(defaultSort ?? null);

  const thProps = useSortingTableDriver(sort, setSort);

  const sortedItems = React.useMemo(
    () =>
      sort
        ? orderBy(
            items,
            (record: Item) => {
              const value = record[sort.key];
              return typeof value === "string" ? value.toLowerCase() : value;
            },
            sort.direction,
          )
        : items,
    [items, sort],
  );

  return {
    items: sortedItems,
    thProps,
  };
};

export const useSortingTableDriver =
  <Item>(sort: Sort<Item> | null, setSort: (sort: Sort<Item>) => void) =>
  (key: Item): React.ComponentProps<typeof TableHead> => ({
    sortDirection: sort?.key === key ? (sort.direction === "asc" ? "ascending" : "descending") : "none",
    onClick: () => setSort({ key, direction: sort?.key === key ? (sort.direction === "asc" ? "desc" : "asc") : "asc" }),
  });
