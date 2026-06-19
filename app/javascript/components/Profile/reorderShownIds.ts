import { sortBy } from "lodash-es";

export const reorderShownIds = (shownIds: string[], newOrder: string[]): string[] =>
  sortBy(shownIds, (id) => {
    const index = newOrder.indexOf(id);
    return index < 0 ? Infinity : index;
  });
