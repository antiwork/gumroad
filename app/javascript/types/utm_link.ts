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
