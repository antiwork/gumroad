export type Discount = ({ type: "percent"; percents: number } | { type: "fixed"; cents: number }) & {
  product_ids: string[] | null;
  expires_at: string | null;
  minimum_quantity: number | null;
  duration_in_billing_cycles: 1 | null;
  minimum_amount_cents: number | null;
};
