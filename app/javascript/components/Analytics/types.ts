export type Product = {
  name: string;
  id: string;
  alive: boolean;
  unique_permalink: string;
};

export type AnalyticsTotal = {
  sales: number;
  views: number;
  totals: number;
};

export type AnalyticsDailyTotal = {
  date: string;
  month: string;
  monthIndex: number;
  sales: number;
  views: number;
  totals: number;
};

export type AnalyticsReferrerTotals = Record<string, AnalyticsTotal>;

export type AnalyticsData = {
  total: AnalyticsTotal;
  startDate: string;
  endDate: string;
  dailyTotal: AnalyticsDailyTotal[];
  referrerTotal: AnalyticsReferrerTotals;
};

export type AnalyticsProps = {
  products: Product[];
  country_codes: Record<string, string>;
  state_names: Record<string, string>;
};
