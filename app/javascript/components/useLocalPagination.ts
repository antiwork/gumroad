import * as React from "react";

export const useLocalPagination = <Item>(
  items: readonly Item[],
  itemsPerPage: number,
): {
  items: Item[];
  showMoreItems: (() => void) | null;
} => {
  const [currentPage, setCurrentPage] = React.useState(1);

  const visibleItems = React.useMemo(() => items.slice(0, currentPage * itemsPerPage), [items, currentPage]);

  const canShowMoreItems = currentPage * itemsPerPage < items.length;

  const showMoreItems = () => {
    setCurrentPage(currentPage + 1);
  };

  return { items: visibleItems, showMoreItems: canShowMoreItems ? showMoreItems : null };
};
