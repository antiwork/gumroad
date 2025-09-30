import { StripeCardElement } from "@stripe/stripe-js";
import cx from "classnames";
import { CountryCode, parsePhoneNumber } from "libphonenumber-js";
import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import { CardPayoutError, prepareCardTokenForPayouts } from "$app/data/card_payout_data";
import { SavedCreditCard } from "$app/parsers/card";
import { SettingPage } from "$app/parsers/settings";
import { formatPriceCentsWithCurrencySymbol, formatPriceCentsWithoutCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { request, assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { PriceInput } from "$app/components/PriceInput";
import { showAlert } from "$app/components/server-components/Alert";
import { ConfirmBalanceForfeitOnPayoutMethodChangeModal } from "$app/components/server-components/ConfirmBalanceForfeitOnPayoutMethodChangeModal";
import { CountrySelectionModal } from "$app/components/server-components/CountrySelectionModal";
import { StripeConnectEmbeddedNotificationBanner } from "$app/components/server-components/PayoutPage/StripeConnectEmbeddedNotificationBanner";
import { CreditCardForm } from "$app/components/server-components/Settings/CreditCardForm";
import { UpdateCountryConfirmationModal } from "$app/components/server-components/UpdateCountryConfirmationModal";
import { Layout } from "$app/components/Settings/Layout";
import AccountDetailsSection from "$app/components/Settings/PaymentsPage/AccountDetailsSection";
import AusBackTaxesSection from "$app/components/Settings/PaymentsPage/AusBackTaxesSection";
import BankAccountSection, {
  BankAccount,
  BankAccountDetails,
} from "$app/components/Settings/PaymentsPage/BankAccountSection";
import DebitCardSection from "$app/components/Settings/PaymentsPage/DebitCardSection";
import PayPalConnectSection, { PayPalConnect } from "$app/components/Settings/PaymentsPage/PayPalConnectSection";
import PayPalEmailSection from "$app/components/Settings/PaymentsPage/PayPalEmailSection";
import StripeConnectSection, { StripeConnect } from "$app/components/Settings/PaymentsPage/StripeConnectSection";
import { Toggle } from "$app/components/Toggle";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { WithTooltip } from "$app/components/WithTooltip";

import logo from "$assets/images/logo-g.svg";

export type PayoutDebitCardData = { type: "saved" } | { type: "new"; element: StripeCardElement } | undefined;

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

const PAYOUT_FREQUENCIES = ["daily", "weekly", "monthly", "quarterly"] as const;
type PayoutFrequency = (typeof PAYOUT_FREQUENCIES)[number];

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
  street_address_kanji?: string | null;
  street_address_kana?: string | null;
  business_building_number?: string | null;
  business_street_address_kanji?: string | null;
  business_street_address_kana?: string | null;
};

type Props = {
  settings_pages: SettingPage[];
  is_form_disabled: boolean;
  should_show_country_modal: boolean;
  aus_backtax_details: {
    show_au_backtax_prompt: boolean;
    total_amount_to_au: string;
    au_backtax_amount: string;
    credit_creation_date: string;
    opt_in_date: string | null;
    opted_in_to_au_backtax: boolean;
    legal_entity_name: string;
    are_au_backtaxes_paid: boolean;
    au_backtaxes_paid_date: string | null;
  };
  show_verification_section: boolean;
  countries: Record<string, string>;
  ip_country_code: string | null;
  bank_account_details: BankAccountDetails;
  paypal_address: string | null;
  stripe_connect: StripeConnect;
  paypal_connect: PayPalConnect;
  fee_info: {
    card_fee_info_text: string;
    paypal_fee_info_text: string;
    connect_account_fee_info_text: string;
  };
  min_dob_year: number;
  user: User;
  compliance_info: ComplianceInfo;
  uae_business_types: { code: string; name: string }[];
  india_business_types: { code: string; name: string }[];
  canada_business_types: { code: string; name: string }[];
  states: {
    us: { code: string; name: string }[];
    ca: { code: string; name: string }[];
    au: { code: string; name: string }[];
    mx: { code: string; name: string }[];
    ae: { code: string; name: string }[];
    ir: { code: string; name: string }[];
    br: { code: string; name: string }[];
  };
  saved_card: SavedCreditCard | null;
  formatted_balance_to_forfeit_on_country_change: string | null;
  formatted_balance_to_forfeit_on_payout_method_change: string | null;
  payouts_paused_internally: boolean;
  payouts_paused_by: "stripe" | "admin" | "system" | "user" | null;
  payouts_paused_for_reason: string | null;
  payouts_paused_by_user: boolean;
  payout_threshold_cents: number;
  minimum_payout_threshold_cents: number;
  payout_frequency: PayoutFrequency;
  payout_frequency_daily_supported: boolean;
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

export type ErrorMessageInfo = {
  message: string;
  code?: string | null;
};

const PaymentsPage = (props: Props) => {
  const userAgentInfo = useUserAgentInfo();
  const [isSaving, setIsSaving] = React.useState(false);
  const [errorMessage, setErrorMessage] = React.useState<ErrorMessageInfo | null>(null);
  const formRef = React.useRef<HTMLDivElement & HTMLFormElement>(null);
  const [errorFieldNames, setErrorFieldNames] = React.useState(() => new Set<FormFieldName>());
  const markFieldInvalid = (fieldName: FormFieldName) => setErrorFieldNames(new Set(errorFieldNames.add(fieldName)));
  const [isUpdateCountryConfirmed, setIsUpdateCountryConfirmed] = React.useState(false);
  const [isPayoutMethodChangeConfirmed, setIsPayoutMethodChangeConfirmed] = React.useState(false);

  const [selectedPayoutMethod, setSelectedPayoutMethod] = React.useState<PayoutMethod>(
    props.stripe_connect.has_connected_stripe
      ? "stripe"
      : props.bank_account_details.show_bank_account && props.bank_account_details.is_a_card
        ? "card"
        : props.bank_account_details.account_number_visual !== null
          ? "bank"
          : props.bank_account_details.show_paypal
            ? "paypal"
            : "bank",
  );
  const updatePayoutMethod = (newPayoutMethod: PayoutMethod) => {
    setSelectedPayoutMethod(newPayoutMethod);
    setErrorFieldNames(new Set());
  };

  const [payoutsPausedByUser, setPayoutsPausedByUser] = React.useState(props.payouts_paused_by_user);

  const [payoutThresholdCents, setPayoutThresholdCents] = React.useState<{ value: number | null; error?: boolean }>({
    value: props.payout_threshold_cents,
  });
  const [payoutFrequency, setPayoutFrequency] = React.useState<PayoutFrequency>(props.payout_frequency);

  const [complianceInfo, setComplianceInfo] = React.useState(props.compliance_info);
  const updateComplianceInfo = (newComplianceInfo: Partial<ComplianceInfo>) => {
    if (props.user.country_code === "AE") {
      if (!complianceInfo.is_business && newComplianceInfo.is_business) updatePayoutMethod("bank");
      else if (complianceInfo.is_business && "is_business" in newComplianceInfo && !newComplianceInfo.is_business)
        updatePayoutMethod("paypal");
    }
    if (
      props.user.country_code &&
      newComplianceInfo.updated_country_code &&
      props.user.country_code !== newComplianceInfo.updated_country_code
    ) {
      setErrorMessage(null);
      setIsUpdateCountryConfirmed(false);
      setShowUpdateCountryConfirmationModal(true);
    }
    setComplianceInfo((prevComplianceInfo) => ({ ...prevComplianceInfo, ...newComplianceInfo }));
    setErrorFieldNames(new Set());
  };

  const [bankAccount, setBankAccount] = React.useState(props.bank_account_details.bank_account);
  const updateBankAccount = (newBankAccount: Partial<BankAccount>) => {
    setBankAccount((prevBankAccount) => ({ ...prevBankAccount, ...newBankAccount }));
    setErrorFieldNames(new Set());
  };

  const [paypalEmailAddress, setPaypalEmailAddress] = React.useState(props.paypal_address);
  const [debitCard, setDebitCard] = React.useState<PayoutDebitCardData | null>(null);
  const [showNewBankAccount, setShowNewBankAccount] = React.useState(!props.bank_account_details.account_number_visual);

  React.useEffect(() => {
    if (errorMessage) formRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [errorMessage]);

  const isStreetAddressPOBox = (input: string) => {
    const countryCode: CountryCode = cast(props.user.country_code);

    return (
      countryCode === "US" &&
      input
        // Removes all non-alphanumeric characters (excluding underscores).
        // The 'g' flag allows to match globally and the 'u' flag treats
        // the pattern as a sequence of Unicode code points (as mandated by
        // the 'require-unicode-regexp' ESLint rule).
        .replace(/[^\w]*/gu, "")
        .toLocaleLowerCase()
        .includes("pobox")
    );
  };

  const validatePhoneNumber = (input: string | null, country_code: string | null) => {
    const countryCode: CountryCode = cast(country_code);
    try {
      return input && parsePhoneNumber(input, countryCode).isValid();
    } catch {
      return false;
    }
  };

  const validateBankAccountFields = () => {
    if (!bankAccount) {
      return;
    }

    if (!bankAccount.account_holder_full_name) {
      markFieldInvalid("account_holder_full_name");
    }
    if (bankAccount.type === "AchAccount" && !bankAccount.routing_number) {
      markFieldInvalid("routing_number");
    }
    if (bankAccount.type === "AustralianBankAccount" && !bankAccount.bsb_number) {
      markFieldInvalid("bsb_number");
    }
    if (bankAccount.type === "CanadianBankAccount" && !bankAccount.transit_number) {
      markFieldInvalid("transit_number");
    }
    if (bankAccount.type === "CanadianBankAccount" && !bankAccount.institution_number) {
      markFieldInvalid("institution_number");
    }
    if (bankAccount.type === "HongKongBankAccount" && !bankAccount.clearing_code) {
      markFieldInvalid("clearing_code");
    }
    if (bankAccount.type === "HongKongBankAccount" && !bankAccount.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (bankAccount.type === "KoreaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "PhilippinesBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "SingaporeanBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "SingaporeanBankAccount" && !bankAccount.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (bankAccount.type === "ThailandBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "TrinidadAndTobagoBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "TrinidadAndTobagoBankAccount" && !bankAccount.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (bankAccount.type === "UkBankAccount" && !bankAccount.sort_code) {
      markFieldInvalid("sort_code");
    }
    if (bankAccount.type === "IndianBankAccount" && !bankAccount.ifsc) {
      markFieldInvalid("ifsc");
    }
    if (bankAccount.type === "VietnamBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "TaiwanBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "IndonesiaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "ChileBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "ChileBankAccount" && !bankAccount.account_type) {
      markFieldInvalid("account_type");
    }
    if (bankAccount.type === "PakistanBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "TurkeyBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "MoroccoBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "JapanBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "MalaysiaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "BosniaAndHerzegovinaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "JapanBankAccount" && !bankAccount.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (bankAccount.type === "BotswanaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "SerbiaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "SouthAfricaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "KenyaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "NorthMacedoniaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "EgyptBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "AntiguaAndBarbudaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "TanzaniaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "NamibiaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "EthiopiaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "BruneiBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "GuyanaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "GuatemalaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "ColombiaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "ColombiaBankAccount" && !bankAccount.account_type) {
      markFieldInvalid("account_type");
    }
    if (bankAccount.type === "SaudiArabiaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "UruguayBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "MauritiusBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "JamaicaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "JamaicaBankAccount" && !bankAccount.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (bankAccount.type === "EcuadorBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "KazakhstanBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "OmanBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "RwandaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "DominicanRepublicBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "UzbekistanBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "UzbekistanBankAccount" && !bankAccount.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (bankAccount.type === "BoliviaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("branch_code");
    }
    if (bankAccount.type === "GhanaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "AlbaniaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "BahrainBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "JordanBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "NigeriaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "AngolaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "SanMarinoBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "AzerbaijanBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "AzerbaijanBankAccount" && !bankAccount.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (bankAccount.type === "MoldovaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "PanamaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "ElSalvadorBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "ParaguayBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "ArmeniaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "SriLankaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "SriLankaBankAccount" && !bankAccount.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (bankAccount.type === "BangladeshBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "BhutanBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "LaosBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "MozambiqueBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "KuwaitBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "QatarBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "BahamasBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "SaintLuciaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "CambodiaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "MongoliaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "AlgeriaBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (bankAccount.type === "MacaoBankAccount" && !bankAccount.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (!bankAccount.account_number) {
      markFieldInvalid("account_number");
    }
    if (!bankAccount.account_number_confirmation) {
      markFieldInvalid("account_number_confirmation");
    }
  };

  const validateComplianceInfoFields = () => {
    if (!complianceInfo.first_name) {
      markFieldInvalid("first_name");
    }
    if (!complianceInfo.last_name) {
      markFieldInvalid("last_name");
    }
    if (complianceInfo.country === "JP") {
      if (!complianceInfo.building_number) {
        markFieldInvalid("building_number");
      }
      if (!complianceInfo.street_address_kanji) {
        markFieldInvalid("street_address_kanji");
      }
      if (!complianceInfo.street_address_kana) {
        markFieldInvalid("street_address_kana");
      }
    } else if (
      !complianceInfo.street_address ||
      (complianceInfo.country === "US" && isStreetAddressPOBox(complianceInfo.street_address))
    ) {
      markFieldInvalid("street_address");
      if (complianceInfo.street_address) {
        setErrorMessage({
          message: "We require a valid physical US address. We cannot accept a P.O. Box as a valid address.",
        });
      }
    }
    if (!complianceInfo.city) {
      markFieldInvalid("city");
    }
    if (complianceInfo.country !== null && complianceInfo.country in props.states && !complianceInfo.state) {
      markFieldInvalid("state");
    }
    if (!complianceInfo.zip_code && complianceInfo.country !== "BW") {
      markFieldInvalid("zip_code");
    }
    if (!validatePhoneNumber(complianceInfo.phone, complianceInfo.country)) {
      markFieldInvalid("phone");
      setErrorMessage({ message: 'Please enter your full phone number, starting with a "+" and your country code.' });
    }
    if (complianceInfo.dob_day === 0) {
      markFieldInvalid("dob_day");
    }
    if (complianceInfo.dob_month === 0) {
      markFieldInvalid("dob_month");
    }
    if (complianceInfo.dob_year === 0) {
      markFieldInvalid("dob_year");
    }
    if (
      complianceInfo.country !== null &&
      complianceInfo.country in props.user.individual_tax_id_needed_countries &&
      !props.user.individual_tax_id_entered &&
      !complianceInfo.individual_tax_id
    ) {
      markFieldInvalid("individual_tax_id");
    }
    if (complianceInfo.is_business) {
      if (!complianceInfo.business_type) {
        markFieldInvalid("business_type");
      }
      if (!complianceInfo.business_name) {
        markFieldInvalid("business_name");
      }
      if (complianceInfo.business_country === "CA") {
        if (!complianceInfo.job_title) {
          markFieldInvalid("job_title");
        }
      }
      if (complianceInfo.business_country === "JP") {
        if (!complianceInfo.business_name_kanji) {
          markFieldInvalid("business_name_kanji");
        }
        if (!complianceInfo.business_name_kana) {
          markFieldInvalid("business_name_kana");
        }
        if (!complianceInfo.business_building_number) {
          markFieldInvalid("business_building_number");
        }
        if (!complianceInfo.business_street_address_kanji) {
          markFieldInvalid("business_street_address_kanji");
        }
        if (!complianceInfo.business_street_address_kana) {
          markFieldInvalid("business_street_address_kana");
        }
      } else if (
        !complianceInfo.business_street_address ||
        (complianceInfo.business_country === "US" && isStreetAddressPOBox(complianceInfo.business_street_address))
      ) {
        markFieldInvalid("business_street_address");
        if (complianceInfo.business_street_address) {
          setErrorMessage({
            message: "We require a valid physical US address. We cannot accept a P.O. Box as a valid address.",
          });
        }
      }
      if (!complianceInfo.business_city) {
        markFieldInvalid("business_city");
      }
      if (
        complianceInfo.business_country !== null &&
        complianceInfo.business_country in props.states &&
        !complianceInfo.business_state
      ) {
        markFieldInvalid("business_state");
      }
      if (!complianceInfo.business_zip_code && props.user.country_code !== "BW") {
        markFieldInvalid("business_zip_code");
      }
      if (!validatePhoneNumber(complianceInfo.business_phone, complianceInfo.business_country)) {
        markFieldInvalid("business_phone");
        setErrorMessage({ message: 'Please enter your full phone number, starting with a "+" and your country code.' });
      }
      if (
        (props.user.country_supports_native_payouts || complianceInfo.business_country === "AE") &&
        !props.user.business_tax_id_entered &&
        !complianceInfo.business_tax_id
      ) {
        markFieldInvalid("business_tax_id");
      }
    }
  };

  const validateForm = () => {
    if (isUpdateCountryConfirmed) {
      return true;
    }

    if (selectedPayoutMethod === "bank" && showNewBankAccount) {
      validateBankAccountFields();
    } else if (selectedPayoutMethod === "paypal" && !paypalEmailAddress) {
      markFieldInvalid("paypal_email_address");
    }

    validateComplianceInfoFields();

    return errorFieldNames.size === 0;
  };

  const handleSave = asyncVoid(async () => {
    if (!validateForm()) return;

    setIsSaving(true);
    setErrorMessage(null);

    let cardData;
    if (selectedPayoutMethod === "card") {
      if (!debitCard || debitCard.type === "saved") {
        cardData = null;
      } else {
        try {
          cardData = await prepareCardTokenForPayouts({ cardElement: debitCard.element });
        } catch (e) {
          if (!(e instanceof CardPayoutError)) throw e;
          cardData = { stripe_error: e.stripeError };
        }
      }
    } else if (
      selectedPayoutMethod === "paypal" &&
      props.bank_account_details.account_number_visual !== null &&
      props.formatted_balance_to_forfeit_on_payout_method_change !== null &&
      !isPayoutMethodChangeConfirmed
    ) {
      setShowPayoutMethodChangeConfirmationModal(true);
      setIsSaving(false);
      return;
    }

    let data = {
      user: complianceInfo,
      payouts_paused_by_user: payoutsPausedByUser,
      payout_threshold_cents: payoutThresholdCents.value,
      payout_frequency: payoutFrequency,
    };

    if (selectedPayoutMethod === "bank") {
      data = { ...data, ...{ bank_account: bankAccount } };
    } else if (selectedPayoutMethod === "card") {
      data = { ...data, ...{ card: cardData } };
    } else if (selectedPayoutMethod === "paypal") {
      data = { ...data, ...{ payment_address: paypalEmailAddress } };
    }

    try {
      const response = await request({
        method: "PUT",
        url: Routes.settings_payments_path(),
        accept: "json",
        data,
      });

      const parsedResponse = cast<
        { success: true } | { success: false; error_message: string; error_code?: string | null }
      >(await response.json());
      if (parsedResponse.success) {
        showAlert("Thanks! You're all set.", "success");
        window.location.reload();
      } else {
        setErrorMessage({ message: parsedResponse.error_message, code: parsedResponse.error_code ?? null });
      }
    } catch (e) {
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }

    setIsSaving(false);
  });

  const [showUpdateCountryConfirmationModal, setShowUpdateCountryConfirmationModal] = React.useState(false);
  const cancelUpdateCountry = () => {
    setShowUpdateCountryConfirmationModal(false);
    setIsUpdateCountryConfirmed(false);
    updateComplianceInfo({ updated_country_code: null });
  };
  const confirmUpdateCountry = () => {
    setShowUpdateCountryConfirmationModal(false);
    setIsUpdateCountryConfirmed(true);
  };
  React.useEffect(() => {
    if (isUpdateCountryConfirmed) {
      handleSave();
    }
  }, [isUpdateCountryConfirmed]);
  const updatedCountry = complianceInfo.updated_country_code
    ? props.countries[complianceInfo.updated_country_code]
    : null;

  const [showPayoutMethodChangeConfirmationModal, setShowPayoutMethodChangeConfirmationModal] = React.useState(false);
  const cancelPayoutMethodChange = () => {
    setShowPayoutMethodChangeConfirmationModal(false);
    setIsPayoutMethodChangeConfirmed(false);
  };
  const confirmPayoutMethodChange = () => {
    setShowPayoutMethodChangeConfirmationModal(false);
    setIsPayoutMethodChangeConfirmed(true);
  };
  React.useEffect(() => {
    if (isPayoutMethodChangeConfirmed) {
      handleSave();
    }
  }, [isPayoutMethodChangeConfirmed]);

  const payoutsPausedToggle = (
    <fieldset>
      <Toggle
        value={payoutsPausedByUser || props.payouts_paused_internally}
        onChange={setPayoutsPausedByUser}
        ariaLabel="Pause payouts"
        disabled={props.is_form_disabled || props.payouts_paused_internally}
      >
        Pause payouts
      </Toggle>
      <small>
        By pausing payouts, they won't be processed until you decide to resume them, and your balance will remain in
        your account until then.
      </small>
    </fieldset>
  );

  return (
    <Layout
      currentPage="payments"
      pages={props.settings_pages}
      onSave={handleSave}
      canUpdate={!props.is_form_disabled && !isSaving && !payoutThresholdCents.error}
    >
      {props.should_show_country_modal ? (
        <CountrySelectionModal country={props.ip_country_code} countries={props.countries} />
      ) : null}
      {updatedCountry ? (
        <UpdateCountryConfirmationModal
          country={updatedCountry}
          balance={props.formatted_balance_to_forfeit_on_country_change}
          open={showUpdateCountryConfirmationModal}
          onConfirm={confirmUpdateCountry}
          onClose={cancelUpdateCountry}
        />
      ) : null}
      {showPayoutMethodChangeConfirmationModal ? (
        <ConfirmBalanceForfeitOnPayoutMethodChangeModal
          balance={props.formatted_balance_to_forfeit_on_payout_method_change}
          open={showPayoutMethodChangeConfirmationModal}
          onConfirm={confirmPayoutMethodChange}
          onClose={cancelPayoutMethodChange}
        />
      ) : null}
      <form ref={formRef}>
        {props.payouts_paused_by !== null ? (
          <div role="status" className="warning mx-8 mb-12">
            <p>
              {props.payouts_paused_by === "stripe" ? (
                <strong>
                  Your payouts are currently paused by our payment processor. Please check for any pending verification
                  requirements below.
                </strong>
              ) : props.payouts_paused_by === "admin" ? (
                <strong>
                  Your payouts have been paused by Gumroad admin.
                  {props.payouts_paused_for_reason ? ` Reason for pause: ${props.payouts_paused_for_reason}` : null}
                </strong>
              ) : props.payouts_paused_by === "system" ? (
                <strong>
                  Your payouts have been automatically paused for a security review and will be resumed once the review
                  completes.
                </strong>
              ) : (
                <strong>You have paused your payouts.</strong>
              )}
            </p>
          </div>
        ) : null}

        <section className="!p-4 md:!p-8">
          <header>
            <h2>Verification</h2>
          </header>
          {props.show_verification_section ? (
            <StripeConnectEmbeddedNotificationBanner />
          ) : (
            <div className="flex flex-col">
              <div role="status" className="success">
                Your account details have been verified!
              </div>
              <div className="mt-4 flex items-center">
                <img src={logo} alt="Gum Coin" className="mr-2 h-5 w-5" />
                <span className="text-muted text-sm">
                  Creator since{" "}
                  {new Date(props.user.joined_at).toLocaleDateString(userAgentInfo.locale, {
                    month: "long",
                    day: "numeric",
                    year: "numeric",
                  })}
                </span>
              </div>
            </div>
          )}
        </section>

        {props.aus_backtax_details.show_au_backtax_prompt ? (
          <AusBackTaxesSection
            total_amount_to_au={props.aus_backtax_details.total_amount_to_au}
            au_backtax_amount={props.aus_backtax_details.au_backtax_amount}
            credit_creation_date={props.aus_backtax_details.credit_creation_date}
            opt_in_date={props.aus_backtax_details.opt_in_date}
            opted_in_to_au_backtax={props.aus_backtax_details.opted_in_to_au_backtax}
            legal_entity_name={props.aus_backtax_details.legal_entity_name}
            are_au_backtaxes_paid={props.aus_backtax_details.are_au_backtaxes_paid}
            au_backtaxes_paid_date={props.aus_backtax_details.au_backtaxes_paid_date}
          />
        ) : null}

        {errorMessage ? (
          <div className="mb-12 px-8">
            <div role="status" className="danger">
              {errorMessage.code === "stripe_error" ? (
                <div>Your account could not be updated due to an error with Stripe.</div>
              ) : (
                errorMessage.message
              )}
            </div>
          </div>
        ) : null}
        <section className="!p-4 md:!p-8">
          <header>
            <h2>Payout schedule</h2>
          </header>
          <section className="paragraphs">
            <fieldset>
              <label htmlFor="payout_frequency">Schedule</label>
              <TypeSafeOptionSelect
                id="payout_frequency"
                name="Schedule"
                value={payoutFrequency}
                onChange={setPayoutFrequency}
                options={PAYOUT_FREQUENCIES.map((frequency) => ({
                  id: frequency,
                  label: frequency.charAt(0).toUpperCase() + frequency.slice(1),
                  disabled: frequency === "daily" && !props.payout_frequency_daily_supported,
                }))}
              />
              <small>
                Daily payouts are only available for US users with eligible bank accounts and more than 4 previous
                payouts.
              </small>
            </fieldset>
            {payoutFrequency === "daily" && props.payout_frequency_daily_supported ? (
              <div role="status" className="info">
                <div>
                  Every day, your balance from the previous day will be sent to you via instant payouts, subject to a{" "}
                  <b>3% fee</b>.
                </div>
              </div>
            ) : null}
            {payoutFrequency === "daily" && !props.payout_frequency_daily_supported && (
              <div role="status" className="danger">
                <div>Your account is no longer eligible for daily payouts. Please update your schedule.</div>
              </div>
            )}
            <fieldset className={cx({ danger: payoutThresholdCents.error })}>
              <label htmlFor="payout_threshold_cents">Minimum payout threshold</label>
              <PriceInput
                id="payout_threshold_cents"
                currencyCode="usd"
                cents={payoutThresholdCents.value}
                disabled={props.is_form_disabled}
                onChange={(value) => {
                  if (value === null || value < props.minimum_payout_threshold_cents) {
                    return setPayoutThresholdCents({ value, error: true });
                  }
                  setPayoutThresholdCents({ value });
                }}
                placeholder={formatPriceCentsWithoutCurrencySymbol("usd", props.minimum_payout_threshold_cents)}
                ariaLabel="Minimum payout threshold"
                hasError={!!payoutThresholdCents.error}
              />
              {payoutThresholdCents.error ? (
                <small>
                  Your payout threshold must be at least{" "}
                  {formatPriceCentsWithCurrencySymbol("usd", props.minimum_payout_threshold_cents, {
                    symbolFormat: "long",
                  })}
                  .
                </small>
              ) : (
                <small>Payouts will only be issued once your balance reaches this amount.</small>
              )}
            </fieldset>
            {props.payouts_paused_internally ? (
              <WithTooltip
                tip={
                  props.payouts_paused_by === "stripe"
                    ? "Your payouts are currently paused by our payment processor. Please check for any pending verification requirements above."
                    : props.payouts_paused_by === "admin"
                      ? `Your payouts have been paused by Gumroad admin.${props.payouts_paused_for_reason && ` Reason for pause: ${props.payouts_paused_for_reason}`}`
                      : props.payouts_paused_by === "system"
                        ? "Your payouts have been automatically paused for a security review and will be resumed once the review completes."
                        : null
                }
              >
                {payoutsPausedToggle}
              </WithTooltip>
            ) : (
              payoutsPausedToggle
            )}
          </section>
        </section>

        <section className="!p-4 md:!p-8">
          <header>
            <h2>Payout method</h2>
            <div>
              <a href="/help/article/260-your-payout-settings-page" target="_blank" rel="noreferrer">
                Any questions about these payout settings?
              </a>
            </div>
          </header>
          <section className="override grid gap-8">
            <div className="radio-buttons" role="radiogroup">
              {props.bank_account_details.show_bank_account ? (
                <>
                  <Button
                    role="radio"
                    key="bank"
                    aria-checked={selectedPayoutMethod === "bank"}
                    onClick={() => updatePayoutMethod("bank")}
                    disabled={props.is_form_disabled}
                  >
                    <Icon name="bank" />
                    <div>
                      <h4>Bank Account</h4>
                    </div>
                  </Button>
                  {props.user.country_code === "US" ? (
                    <Button
                      role="radio"
                      key="card"
                      aria-checked={selectedPayoutMethod === "card"}
                      onClick={() => updatePayoutMethod("card")}
                      disabled={props.is_form_disabled}
                    >
                      <Icon name="card" />
                      <div>
                        <h4>Debit Card</h4>
                      </div>
                    </Button>
                  ) : null}
                </>
              ) : null}
              {props.bank_account_details.show_paypal ? (
                <Button
                  role="radio"
                  key="paypal"
                  aria-checked={selectedPayoutMethod === "paypal"}
                  onClick={() => updatePayoutMethod("paypal")}
                  disabled={props.is_form_disabled}
                >
                  <Icon name="shop-window" />
                  <div>
                    <h4>PayPal</h4>
                  </div>
                </Button>
              ) : null}
              {props.user.country_code === "BR" ||
              props.user.can_connect_stripe ||
              props.stripe_connect.has_connected_stripe ? (
                <Button
                  role="radio"
                  key="stripe"
                  aria-checked={selectedPayoutMethod === "stripe"}
                  onClick={() => updatePayoutMethod("stripe")}
                  disabled={props.is_form_disabled}
                >
                  <Icon name="stripe" />
                  <div>
                    <h4>Connect to Stripe</h4>
                  </div>
                </Button>
              ) : null}
            </div>
            {selectedPayoutMethod === "bank" ? (
              <BankAccountSection
                bankAccountDetails={props.bank_account_details}
                bankAccount={bankAccount}
                updateBankAccount={updateBankAccount}
                hasConnectedStripe={props.stripe_connect.has_connected_stripe}
                user={props.user}
                isFormDisabled={props.is_form_disabled}
                feeInfoText={props.fee_info.card_fee_info_text}
                showNewBankAccount={showNewBankAccount}
                setShowNewBankAccount={setShowNewBankAccount}
                errorFieldNames={errorFieldNames}
              />
            ) : selectedPayoutMethod === "card" ? (
              <DebitCardSection
                isFormDisabled={props.is_form_disabled}
                hasConnectedStripe={props.stripe_connect.has_connected_stripe}
                feeInfoText={props.fee_info.card_fee_info_text}
                savedCard={props.bank_account_details.card}
                setDebitCard={setDebitCard}
              />
            ) : selectedPayoutMethod === "paypal" ? (
              <PayPalEmailSection
                countrySupportsNativePayouts={props.user.country_supports_native_payouts}
                showPayPalPayoutsFeeNote={props.user.is_charged_paypal_payout_fee}
                isFormDisabled={props.is_form_disabled}
                paypalEmailAddress={paypalEmailAddress}
                setPaypalEmailAddress={setPaypalEmailAddress}
                hasConnectedStripe={props.stripe_connect.has_connected_stripe}
                feeInfoText={props.fee_info.paypal_fee_info_text}
                updatePayoutMethod={updatePayoutMethod}
                errorFieldNames={errorFieldNames}
                user={props.user}
              />
            ) : null}
            {selectedPayoutMethod !== "stripe" ? (
              <AccountDetailsSection
                user={props.user}
                complianceInfo={complianceInfo}
                updateComplianceInfo={updateComplianceInfo}
                minDobYear={props.min_dob_year}
                isFormDisabled={props.is_form_disabled}
                countries={props.countries}
                uaeBusinessTypes={props.uae_business_types}
                indiaBusinessTypes={props.india_business_types}
                canadaBusinessTypes={props.canada_business_types}
                states={props.states}
                errorFieldNames={errorFieldNames}
                payoutMethod={selectedPayoutMethod}
              />
            ) : (
              <StripeConnectSection
                stripeConnect={props.stripe_connect}
                isFormDisabled={props.is_form_disabled}
                connectAccountFeeInfoText={props.fee_info.connect_account_fee_info_text}
              />
            )}
          </section>
        </section>
        {props.paypal_connect.show_paypal_connect ? (
          <PayPalConnectSection
            paypalConnect={props.paypal_connect}
            isFormDisabled={props.is_form_disabled}
            connectAccountFeeInfoText={props.fee_info.connect_account_fee_info_text}
          />
        ) : null}
        {props.saved_card ? (
          <CreditCardForm
            card={props.saved_card}
            can_remove={!props.is_form_disabled && !props.user.requires_credit_card}
            read_only={props.is_form_disabled}
          />
        ) : null}
      </form>
    </Layout>
  );
};

export default register({ component: PaymentsPage, propParser: createCast() });
