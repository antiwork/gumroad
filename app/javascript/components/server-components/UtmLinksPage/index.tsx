import * as React from "react";

import { SavedUtmLink, UtmLink, UtmLinkFormContext, SortKey } from "$app/data/utm_links";

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

export const extractSortParam = (rawParams: URLSearchParams): Sort<SortKey> | null => {
  const column = rawParams.get("key");
  switch (column) {
    case "link":
    case "date":
    case "source":
    case "medium":
    case "campaign":
    case "clicks":
    case "sales_count":
    case "revenue_cents":
    case "conversion_rate":
      return {
        key: column,
        direction: rawParams.get("direction") === "desc" ? "desc" : "asc",
      };
    default:
      return null;
  }
};

export type UtmLinksPageProps = {
  utm_links: SavedUtmLink[];
  pagination: PaginationProps;
  context: UtmLinkFormContext;
  utm_link?: UtmLink;
  copy_from?: string;
};

const UtmLinksPage = ({ utm_links, pagination, context, utm_link, copy_from }: UtmLinksPageProps) => {
  const currentPath = window.location.pathname;

  return currentPath === "/dashboard/utm_links/new" ? (
    <UtmLinkForm context={context} utm_link={utm_link ?? null} {...(copy_from && { copy_from })} />
  ) : /\/dashboard\/utm_links\/\d+\/edit$/u.exec(currentPath) ? (
    <UtmLinkForm context={context} utm_link={utm_link ?? null} />
  ) : (
    <UtmLinkList utm_links={utm_links} pagination={pagination} />
  );
};

export default UtmLinksPage;
