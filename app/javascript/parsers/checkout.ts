export type Discount =
  | ({
      type: "percent";
      percents: number;
      tiered?: boolean;
      min_percents?: number;
      max_percents?: number;
    } & DiscountConditions)
  | ({ type: "fixed"; cents: number } & DiscountConditions);

type DiscountConditions = {
  product_ids: string[] | null;
  expires_at: string | null;
  minimum_quantity: number | null;
  duration_in_billing_cycles: 1 | null;
  minimum_amount_cents: number | null;
};
