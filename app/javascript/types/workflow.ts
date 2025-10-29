import type { FileItem } from "$app/components/EmailAttachments";
export type WorkflowType = "audience" | "seller" | "product" | "variant" | "follower" | "affiliate" | "abandoned_cart";
export type LegacyWorkflowTrigger = "member_cancellation" | null;
export type SaveActionName = "save" | "save_and_publish" | "save_and_unpublish";

export const INSTALLMENT_DELIVERY_TIME_PERIODS = ["hour", "day", "week", "month"] as const;
export type InstallmentDeliveryTimePeriod = (typeof INSTALLMENT_DELIVERY_TIME_PERIODS)[number];

export type Installment = {
  name: string;
  message: string;
  files: FileItem[];
  published_once_already: boolean;
  member_cancellation: boolean;
  external_id: string;
  stream_only: boolean;
  call_to_action_text: string | null;
  call_to_action_url: string | null;
  new_customers_only: boolean;
  streamable: boolean;
  sent_count: number | null;
  click_count: number;
  open_count: number;
  click_rate: number | null;
  open_rate: number | null;
  delayed_delivery_time_duration: number;
  delayed_delivery_time_period: InstallmentDeliveryTimePeriod;
  displayed_delayed_delivery_time_period: string;
};

export type Post = {
  id: string;
  name: string;
  date:
    | { type: "workflow_email_rule"; time_duration: number; time_period: InstallmentDeliveryTimePeriod }
    | { type: "date"; value: string };
  url: string;
};

export type AbandonedCartProduct = {
  unique_permalink: string;
  name: string;
  url: string;
  thumbnail_url: string | null;
  variants: {
    external_id: string;
    name: string;
  }[];
};

export type Workflow = {
  external_id: string;
  name: string;
  workflow_type: WorkflowType;
  workflow_trigger: LegacyWorkflowTrigger;
  published: boolean;
  first_published_at: string | null;
  send_to_past_customers: boolean;
  installments: Installment[];
  bought_products?: string[];
  not_bought_products?: string[];
  bought_variants?: string[];
  not_bought_variants?: string[];
  paid_more_than?: string;
  paid_less_than?: string;
  created_after?: string;
  created_before?: string;
  bought_from?: string;
  affiliate_products?: string[];
  unique_permalink?: string;
  variant_external_id?: string;
  abandoned_cart_products?: AbandonedCartProduct[];
  seller_has_products?: boolean;
};

export type ProductOption = {
  id: string;
  label: string;
  archived: boolean;
  product_permalink: string;
  type: "product";
};

export type VariantOption = {
  id: string;
  label: string;
  archived: boolean;
  product_permalink: string;
  type: "variant";
};

export type WorkflowFormContext = {
  products_and_variant_options: (ProductOption | VariantOption)[];
  affiliate_product_options: ProductOption[];
  timezone: string;
  currency_symbol: string;
  countries: string[];
  aws_access_key_id: string;
  s3_url: string;
  user_id: string;
  gumroad_address: string;
  eligible_for_abandoned_cart_workflows: boolean;
};
