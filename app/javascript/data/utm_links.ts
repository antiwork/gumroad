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

export type UtmLinkFormStatic = {
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

export type UtmLinkFormDynamic = {
  new_permalink?: string;
};

export type UtmLinkNewPageProps = {
  form_static: UtmLinkFormStatic;
  form_dynamic?: UtmLinkFormDynamic;
  utm_link: UtmLink | null;
};

export type UtmLinkEditPageProps = {
  form_static: UtmLinkFormStatic;
  utm_link: SavedUtmLink;
};

export type UtmLinkIndexPageProps = {
  utm_links_props: {
    utm_links: SavedUtmLink[];
    pagination: import("$app/components/Pagination").PaginationProps;
  };
  utm_links_stats?: UtmLinksStats;
};

export type UtmLinkFormData = {
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
