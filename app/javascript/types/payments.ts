import { StripeCardElement } from "@stripe/stripe-js";

export type User = {
  country_supports_native_payouts: boolean;
  country_supports_iban: boolean;
  need_full_ssn: boolean;
  country_code: string | null;
  payout_currency: string | null;
  is_from_europe: boolean;
  individual_tax_id_needed_countries: string[];
  individual_tax_id_entered: boolean;
  business_tax_id_entered: boolean;
  requires_credit_card: boolean;
  can_connect_stripe: boolean;
  is_charged_paypal_payout_fee: boolean;
  joined_at: string;
};

export type ComplianceInfo = {
  is_business: boolean;
  business_name: string | null;
  business_type: string | null;
  business_street_address: string | null;
  business_city: string | null;
  business_state: string | null;
  business_country: string | null;
  business_zip_code: string | null;
  business_phone: string | null;
  job_title: string | null;
  business_tax_id?: string | null;
  first_name: string | null;
  last_name: string | null;
  street_address: string | null;
  city: string | null;
  state: string | null;
  country: string | null;
  zip_code: string | null;
  phone: string | null;
  nationality: string | null;
  dob_month: number;
  dob_day: number;
  dob_year: number;
  individual_tax_id?: string | null;
  updated_country_code?: string | null;
  first_name_kanji?: string | null;
  last_name_kanji?: string | null;
  first_name_kana?: string | null;
  last_name_kana?: string | null;
  business_name_kanji?: string | null;
  business_name_kana?: string | null;
  building_number?: string | null;
  building_number_kana?: string | null;
  street_address_kanji?: string | null;
  street_address_kana?: string | null;
  business_building_number?: string | null;
  business_building_number_kana?: string | null;
  business_street_address_kanji?: string | null;
  business_street_address_kana?: string | null;
};

export type PayoutMethod = "bank" | "card" | "paypal" | "stripe";
export type FormFieldName =
  | "first_name"
  | "last_name"
  | "first_name_kanji"
  | "last_name_kanji"
  | "first_name_kana"
  | "last_name_kana"
  | "building_number"
  | "building_number_kana"
  | "street_address_kanji"
  | "street_address_kana"
  | "street_address"
  | "city"
  | "state"
  | "zip_code"
  | "dob_year"
  | "dob_month"
  | "dob_day"
  | "phone"
  | "nationality"
  | "individual_tax_id"
  | "business_type"
  | "business_name"
  | "business_name_kanji"
  | "business_name_kana"
  | "business_street_address"
  | "business_building_number"
  | "business_building_number_kana"
  | "business_street_address_kanji"
  | "business_street_address_kana"
  | "business_city"
  | "business_state"
  | "business_zip_code"
  | "business_phone"
  | "job_title"
  | "business_tax_id"
  | "routing_number"
  | "transit_number"
  | "institution_number"
  | "bsb_number"
  | "bank_code"
  | "branch_code"
  | "clearing_code"
  | "sort_code"
  | "ifsc"
  | "account_type"
  | "account_holder_full_name"
  | "account_number"
  | "account_number_confirmation"
  | "paypal_email_address";

export type PayoutDebitCardData = { type: "saved" } | { type: "new"; element: StripeCardElement } | undefined;
