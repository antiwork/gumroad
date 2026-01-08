import { range } from "lodash-es";
import * as React from "react";

import { isOpenTuple, last } from "$app/utils/array";
import { assert } from "$app/utils/assert";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";

export type PaginationProps = { pages: number; page: number };

type Props = {
  pagination: PaginationProps;
  pageDisplayCount?: number;
  onChangePage: (page: number) => void;
};

const PageNumber = ({ page, isCurrent, onClick }: { page: number; isCurrent: boolean; onClick: () => void }) => (
  <li>
    <Button
      small
      color={isCurrent ? "primary" : undefined}
      aria-current={isCurrent ? "page" : undefined}
      onClick={() => (isCurrent ? null : onClick())}
    >
      {page}
    </Button>
  </li>
);

export const Pagination = ({ pagination, pageDisplayCount = 10, onChangePage }: Props) => {
  const { pages, firstBoundaryPageShown, lastBoundaryPageShown } = React.useMemo(() => {
    const pagesShown = Math.min(pageDisplayCount, pagination.pages);
    const firstShownPage = Math.min(
      Math.max(pagination.page - Math.floor(pagesShown / 2), 1),
      1 + pagination.pages - pagesShown,
    );
    const allPages = range(firstShownPage, firstShownPage + pagesShown);
    assert(isOpenTuple(allPages, 1), "Pagination cannot be rendered with 0 pages");

    const firstBoundaryPageShown = allPages[0] > 1 && pagination.page > 2;
    const lastBoundaryPageShown = last(allPages) < pagination.pages && pagination.page < pagination.pages - 1;
    return {
      pages: allPages.slice(
        firstBoundaryPageShown ? 1 : 0,
        lastBoundaryPageShown ? allPages.length - 1 : allPages.length,
      ),
      firstBoundaryPageShown,
      lastBoundaryPageShown,
    };
  }, [pagination, pageDisplayCount]);

  return (
    <div role="navigation" aria-label="Pagination" className="flex w-full justify-center gap-2">
      <Button small disabled={pagination.page - 1 === 0} onClick={() => onChangePage(pagination.page - 1)}>
        <Icon name="outline-cheveron-left" />
        Previous
      </Button>
      <menu className="hidden! flex-1 justify-center gap-2 lg:flex!">
        {firstBoundaryPageShown ? (
          <>
            <PageNumber page={1} isCurrent={pagination.page === 1} onClick={() => onChangePage(1)} />
            ...
          </>
        ) : null}
        {pages.map((page) => (
          <PageNumber key={page} page={page} isCurrent={pagination.page === page} onClick={() => onChangePage(page)} />
        ))}
        {lastBoundaryPageShown ? (
          <>
            ...
            <PageNumber
              page={pagination.pages}
              isCurrent={pagination.page === pagination.pages}
              onClick={() => onChangePage(pagination.pages)}
            />
          </>
        ) : null}
      </menu>
      <Button small disabled={pagination.page + 1 > pagination.pages} onClick={() => onChangePage(pagination.page + 1)}>
        Next
        <Icon name="outline-cheveron-right" />
      </Button>
    </div>
  );
};
