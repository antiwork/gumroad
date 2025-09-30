import * as React from "react";

import { SavedUtmLink, UtmLink, UtmLinkFormContext, SortKey } from "$app/data/utm_links";
import * as Routes from "$app/utils/routes";

import { PaginationProps } from "$app/components/Pagination";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Sort } from "$app/components/useSortingTableDriver";

import { UtmLinkForm } from "./UtmLinkForm";
import UtmLinkList from "./UtmLinkList";

export const UtmLinkLayout = ({
  title,
  actions,
  children,
}: {
  title: string;
  actions?: React.ReactNode;
  children: React.ReactNode;
}) => (
  <div>
    <PageHeader title={title} actions={actions} />
    {children}
  </div>
);

const VALID_SORT_COLUMNS = new Set([
  "link",
  "date",
  "source",
  "medium",
  "campaign",
  "clicks",
  "sales_count",
  "revenue_cents",
  "conversion_rate",
]);

const isValidSortKey = (value: string): value is SortKey => VALID_SORT_COLUMNS.has(value);

export const extractSortParam = (rawParams: URLSearchParams): Sort<SortKey> | null => {
  const column = rawParams.get("key");
  if (column && isValidSortKey(column)) {
    return {
      key: column,
      direction: rawParams.get("direction") === "desc" ? "desc" : "asc",
    };
  }
  return null;
};

export type UtmLinksPageProps = {
  utm_links: SavedUtmLink[];
  pagination: PaginationProps;
  context: UtmLinkFormContext;
  utm_link?: UtmLink | undefined;
  copy_from?: string | undefined;
};

const UtmLinksPage = ({ utm_links, pagination, context, utm_link, copy_from }: UtmLinksPageProps) => {
  const currentPath = window.location.pathname;
  const newUtmLinkPath = Routes.new_dashboard_utm_link_path();
  const editUtmLinkRegex = /\/dashboard\/utm_links\/\d+\/edit$/u;

  if (currentPath === newUtmLinkPath) {
    return <UtmLinkForm context={context} utm_link={utm_link ?? null} {...(copy_from && { copy_from })} />;
  }

  if (editUtmLinkRegex.test(currentPath)) {
    return <UtmLinkForm context={context} utm_link={utm_link ?? null} />;
  }

  return <UtmLinkList utm_links={utm_links} pagination={pagination} />;
};

export default UtmLinksPage;
