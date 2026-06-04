import { type PaginationProps } from "$app/components/Pagination";

type StripeConnectAccount = { payout_method_type: "stripe_connect"; stripe_connect_account_id: string };
type NoPayoutAccount = { payout_method_type: "none" };

// Some past payouts have no associated payout accounts, which is a different state than no (current) payout account
type LegacyNotAvailableAccount = { payout_method_type: "legacy-na" };

export type BankAccount =
  | {
      payout_method_type: "bank";
      bank_account_type: "ACH";
      bank_number: string;
      routing_number: string;
      account_number: string;
      bank_name?: string;
    }
  | { payout_method_type: "bank"; bank_account_type: "AE"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "AR"; account_number: string }
  | {
      payout_method_type: "bank";
      bank_account_type: "AUSTRALIAN";
      bank_number: string;
      routing_number: string;
      account_number: string;
      bank_name?: string;
      bsb_number: string;
    }
  | { payout_method_type: "bank"; bank_account_type: "BG"; account_number: string }
  | {
      payout_method_type: "bank";
      bank_account_type: "CANADIAN";
      bank_number: string;
      routing_number: string;
      account_number: string;
      bank_name?: string;
      transit_number: string;
      institution_number: string;
    }
  | {
      payout_method_type: "bank";
      bank_account_type: "CARD";
      routing_number: string;
      account_number: string;
      bank_name?: string;
    }
  | { payout_method_type: "bank"; bank_account_type: "CH"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "CZ"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "DK"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "EU"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "HK"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "HU"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "IL"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "KR"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MX"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "NZ"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "PE"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "PH"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "PK"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "PL"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "RO"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "SE"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "TZ"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "AG"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "NA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "SG"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "TH"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "TR"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "TT"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "IN"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "VN"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "TW"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "ET"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BN"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "GY"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "GT"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "ID"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "ZA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "KE"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "EG"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "CO"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "CR"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "NO"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BW"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "RS"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "CL"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "SA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "LI"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "JP"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "KZ"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "EC"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MY"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "UY"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MU"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "JM"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "OM"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "DO"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "UZ"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BO"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "RW"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "TN"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "JO"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "AL"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "AO"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "NE"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "SM"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BH"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "NG"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "AZ"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MD"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MK"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "PA"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "SV"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "PY"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "GH"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "AM"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "LK"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BD"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BT"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "LA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MZ"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "KW"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MG"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "IS"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "QA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BS"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "LC"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "SN"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "KH"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MN"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "DZ"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MO"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BJ"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "CI"; account_number: string }
  | {
      payout_method_type: "bank";
      bank_account_type: "UK";
      bank_number: string;
      routing_number: string;
      account_number: string;
      bank_name?: string;
    }
  | {
      payout_method_type: "bank";
      bank_account_type: "GI";
      routing_number: string;
      account_number: string;
    }
  | { payout_method_type: "bank"; bank_account_type: "GA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MC"; account_number: string };

export type PaypalAccount = { payout_method_type: "paypal"; paypal_address: string };

type CurrentPayoutsDataWithUserNotPayable = {
  status: "not_payable";
  should_be_shown_currencies_always: boolean;
  minimum_payout_amount_cents: number;
  payout_note?: string | null;
  has_stripe_connect: boolean;
};

type CurrentPayoutStatus = "paused" | "payable" | "processing" | "completed";
type PayoutType = "standard" | "instant";

type CurrentPeriodPayoutData = (
  | { status: "processing"; payment_external_id: string; arrival_date: string | null; type: PayoutType }
  | { status: Exclude<CurrentPayoutStatus, "processing" | "completed"> }
) & {
  has_stripe_connect: boolean;
  should_be_shown_currencies_always: boolean;
  displayable_payout_period_range: string;
  payout_currency: string;
  payout_cents: number;
  payout_displayed_amount: string;
  payout_date_formatted: string;
  sales_cents: number;
  refunds_cents: number;
  chargebacks_cents: number;
  credits_cents: number;
  fees_cents: number;
  discover_fees_cents: number;
  direct_fees_cents: number;
  discover_sales_count: number;
  direct_sales_count: number;
  taxes_cents: number;
  affiliate_credits_cents: number;
  affiliate_fees_cents: number;
  paypal_payout_cents: number;
  stripe_connect_payout_cents: number;
  loan_repayment_cents: number;
  payout_note?: string | null;
};

type PastPeriodPayoutsData = {
  status: "completed";
  should_be_shown_currencies_always: boolean;
  displayable_payout_period_range: string;
  payout_currency: string;
  payout_cents: number;
  payout_displayed_amount: string;
  is_processing: boolean;
  arrival_date: string | null;
  payment_external_id: string;
  payout_date_formatted: string;
  sales_cents: number;
  refunds_cents: number;
  chargebacks_cents: number;
  credits_cents: number;
  fees_cents: number;
  discover_fees_cents: number;
  direct_fees_cents: number;
  discover_sales_count: number;
  direct_sales_count: number;
  taxes_cents: number;
  affiliate_credits_cents: number;
  affiliate_fees_cents: number;
  paypal_payout_cents: number;
  stripe_connect_payout_cents: number;
  loan_repayment_cents: number;
  type: PayoutType;
};

export type PayoutsProps = {
  next_payout_period_data:
    | CurrentPayoutsDataWithUserNotPayable
    | CurrentPayoutsDataAndPaymentMethodWithUserPayable
    | null;
  processing_payout_periods_data: PayoutPeriodData[];
  payouts_status: "paused" | "payable";
  payouts_paused_by: "stripe" | "admin" | "system" | "user" | null;
  past_payout_period_data: PayoutPeriodData[];
  instant_payout: {
    payable_amount_cents: number;
    payable_balances: {
      id: string;
      date: string;
      amount_cents: number;
    }[];
    bank_account_type: string;
    bank_name: string | null;
    routing_number: string;
    account_number: string;
  } | null;
  show_instant_payouts_notice: boolean;
  pagination: PaginationProps;
  tax_center_enabled: boolean;
  scheduled_payout: {
    action: "refund" | "payout" | "hold";
    status: "pending" | "flagged" | "held" | "executed";
    scheduled_at: string;
    payout_amount_cents: number | null;
  } | null;
};

type PaymentMethod = NoPayoutAccount | BankAccount | PaypalAccount | StripeConnectAccount;
type LegacyPaymentMethod = LegacyNotAvailableAccount | BankAccount | PaypalAccount | StripeConnectAccount;

export type CurrentPayoutsDataAndPaymentMethodWithUserPayable = CurrentPeriodPayoutData & PaymentMethod;

export type PastPayoutsDataAndPaymentMethod = PastPeriodPayoutsData & LegacyPaymentMethod;

type PayoutPeriodData = CurrentPayoutsDataAndPaymentMethodWithUserPayable | PastPayoutsDataAndPaymentMethod;
