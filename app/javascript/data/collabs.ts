export type Product = {
  id: number;
  edit_url: string;
  name: string;
  permalink: string;
  successful_sales_count: number;
  remaining_for_sale_count: number | null;
  display_price_cents: number;
  revenue: number;
  price_formatted: string;
  thumbnail: { url: string } | null;
  url: string;
  url_without_protocol: string;
  cut: number;
  can_edit: boolean;
};

export type Membership = Product & {
  has_duration: boolean;
  monthly_recurring_revenue: number;
  revenue_pending: number;
};
