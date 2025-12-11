import type { PaginationProps } from "$app/components/Pagination";
import type { Sort } from "$app/components/useSortingTableDriver";

export type UtmLinkDestinationOption = {
  id: string;
  label: string;
  url: string;
};

export type UtmLink = {
  id?: string;
  destination_option?: UtmLinkDestinationOption;
  title: string;
  short_url: string;
  utm_url: string;
  created_at: string;
  source: string;
  medium: string;
  campaign: string;
  term: string | null;
  content: string | null;
  clicks: number;
  sales_count: number | null;
  revenue_cents: number | null;
  conversion_rate: number | null;
};

export type SavedUtmLink = UtmLink & {
  id: string;
};

export type UtmLinkStats = {
  sales_count: number | null;
  revenue_cents: number | null;
  conversion_rate: number | null;
};

export type UtmLinksStats = Record<string, UtmLinkStats>;

export type UtmLinkFormContext = {
  destination_options: UtmLinkDestinationOption[];
  short_url: string;
  utm_fields_values: {
    campaigns: string[];
    mediums: string[];
    sources: string[];
    terms: string[];
    contents: string[];
  };
};

export type UtmLinkRequestPayload = {
  title: string;
  target_resource_type: string;
  target_resource_id: string | null;
  permalink: string;
  utm_source: string;
  utm_medium: string;
  utm_campaign: string;
  utm_term: string | null;
  utm_content: string | null;
};

export type SortKey =
  | "link"
  | "date"
  | "source"
  | "medium"
  | "campaign"
  | "clicks"
  | "sales_count"
  | "revenue_cents"
  | "conversion_rate";

export type UtmLinksIndexProps = {
  utm_links: SavedUtmLink[];
  pagination: PaginationProps;
  query: string | null;
  sort: Sort<SortKey> | null;
};

export type UtmLinkFormProps = {
  context: UtmLinkFormContext;
  utm_link: UtmLink | null;
};

export type UtmLinkEditProps = {
  context: UtmLinkFormContext;
  utm_link: SavedUtmLink;
};
