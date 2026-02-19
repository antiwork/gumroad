import { useForm, usePage } from "@inertiajs/react";
import parsePhoneNumberFromString, { CountryCode } from "libphonenumber-js";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { CardPayoutError, prepareCardTokenForPayouts, type CardPayoutToken } from "$app/data/card_payout_data";
import { SavedCreditCard } from "$app/parsers/card";
import { SettingPage } from "$app/parsers/settings";
import type { ComplianceInfo, PayoutMethod, FormFieldName, User, PayoutDebitCardData } from "$app/types/payments";
import { formatPriceCentsWithCurrencySymbol, formatPriceCentsWithoutCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";

import { Button } from "$app/components/Button";
import { ConfirmBalanceForfeitOnPayoutMethodChangeModal } from "$app/components/ConfirmBalanceForfeitOnPayoutMethodChangeModal";
import { CountrySelectionModal } from "$app/components/CountrySelectionModal";
import { Icon } from "$app/components/Icons";
import { StripeConnectEmbeddedNotificationBanner } from "$app/components/PayoutPage/StripeConnectEmbeddedNotificationBanner";
import { PriceInput } from "$app/components/PriceInput";
import { CreditCardForm } from "$app/components/Settings/AdvancedPage/CreditCardForm";
import { Layout } from "$app/components/Settings/Layout";
import AccountDetailsSection from "$app/components/Settings/PaymentsPage/AccountDetailsSection";
import AusBackTaxesSection, { type AusBacktaxDetails } from "$app/components/Settings/PaymentsPage/AusBackTaxesSection";
import BankAccountSection, {
  BankAccountDetails,
  type BankAccount,
} from "$app/components/Settings/PaymentsPage/BankAccountSection";
import DebitCardSection from "$app/components/Settings/PaymentsPage/DebitCardSection";
import PayPalConnectSection, { PayPalConnect } from "$app/components/Settings/PaymentsPage/PayPalConnectSection";
import PayPalEmailSection from "$app/components/Settings/PaymentsPage/PayPalEmailSection";
import StripeConnectSection, { StripeConnect } from "$app/components/Settings/PaymentsPage/StripeConnectSection";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Alert } from "$app/components/ui/Alert";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { Label } from "$app/components/ui/Label";
import { Switch } from "$app/components/ui/Switch";
import { Tab, Tabs } from "$app/components/ui/Tabs";
import { UpdateCountryConfirmationModal } from "$app/components/UpdateCountryConfirmationModal";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { WithTooltip } from "$app/components/WithTooltip";

import logo from "$assets/images/logo-g.svg";

const KANA_NAME_REGEX = /^[\u30A0-\u30FF\u31F0-\u31FF\uFF65-\uFF9F\s\-.]*$/u;
const KANA_ADDRESS_REGEX = /^[\u30A0-\u30FF\u31F0-\u31FF\uFF65-\uFF9F\p{Script=Latin}\d\s\-.]*$/u;

const KANA_NAME_ERROR = "may only contain katakana characters, spaces, dashes, and dots.";
const KANA_ADDRESS_ERROR = "may only contain katakana, latin characters, digits, spaces, dashes, and dots.";

const HAS_JAPANESE_CHARS = /[\u3000-\u303F\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\uFF65-\uFF9F]/u;

const PAYOUT_FREQUENCIES = ["daily", "weekly", "monthly", "quarterly"] as const;
type PayoutFrequency = (typeof PAYOUT_FREQUENCIES)[number];

type PaymentsPageProps = {
  settings_pages: SettingPage[];
  is_form_disabled: boolean;
  should_show_country_modal: boolean;
  aus_backtax_details: AusBacktaxDetails & {
    show_au_backtax_prompt: boolean;
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
    jp: { value: string; label: string; kana: string }[];
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
  payout_country_name: string | null;
  payout_frequency: PayoutFrequency;
  payout_frequency_daily_supported: boolean;
  errors?: {
    base?: string[];
    error_code?: string[];
  };
};

type ErrorMessageInfo = {
  message: string;
  code?: string | null;
};

export default function PaymentsPage() {
  const page = usePage();
  const props = cast<PaymentsPageProps>(page.props);
  const errors = cast<{ base?: string[]; error_code?: string[] } | undefined>(page.props.errors);

  const userAgentInfo = useUserAgentInfo();
  const [clientErrorMessage, setClientErrorMessage] = React.useState<ErrorMessageInfo | null>(null);
  const formRef = React.useRef<HTMLDivElement & HTMLFormElement>(null);
  const [errorFieldNames, setErrorFieldNames] = React.useState(() => new Set<FormFieldName>());
  const markFieldInvalid = (fieldName: FormFieldName) => setErrorFieldNames(new Set(errorFieldNames.add(fieldName)));
  const [isUpdateCountryConfirmed, setIsUpdateCountryConfirmed] = React.useState(false);
  const [isPayoutMethodChangeConfirmed, setIsPayoutMethodChangeConfirmed] = React.useState(false);

  const form = useForm<{
    user: ComplianceInfo;
    payouts_paused_by_user: boolean;
    payout_threshold_cents: number | null;
    payout_frequency: PayoutFrequency;
    bank_account: Partial<BankAccount> | null;
    payment_address: string | null;
  }>({
    user: props.compliance_info,
    payouts_paused_by_user: props.payouts_paused_by_user,
    payout_threshold_cents: props.payout_threshold_cents,
    payout_frequency: props.payout_frequency,
    bank_account: props.bank_account_details.bank_account,
    payment_address: props.paypal_address,
  });

  const [selectedPayoutMethod, setSelectedPayoutMethod] = React.useState<PayoutMethod>(() =>
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
    if (props.user.country_code === "AE") {
      if (newPayoutMethod === "paypal") {
        form.setData("user", { ...form.data.user, is_business: false });
      } else if (newPayoutMethod === "bank") {
        form.setData("user", { ...form.data.user, is_business: true });
      }
    }
  };

  const updateComplianceInfo = (newComplianceInfo: Partial<ComplianceInfo>) => {
    if (
      props.user.country_code &&
      newComplianceInfo.updated_country_code &&
      props.user.country_code !== newComplianceInfo.updated_country_code
    ) {
      setIsUpdateCountryConfirmed(false);
      setShowUpdateCountryConfirmationModal(true);
    }
    form.setData("user", { ...form.data.user, ...newComplianceInfo });
    setErrorFieldNames(new Set());
  };

  const updateBankAccount = (newBankAccount: Partial<BankAccount>) => {
    form.setData("bank_account", { ...form.data.bank_account, ...newBankAccount });
    setErrorFieldNames(new Set());
  };

  const [debitCard, setDebitCard] = React.useState<PayoutDebitCardData | null>(null);
  const [showNewBankAccount, setShowNewBankAccount] = React.useState(!props.bank_account_details.account_number_visual);
  const previousCountryRef = React.useRef<string | null>(
    props.compliance_info.is_business ? props.compliance_info.business_country : props.compliance_info.country,
  );

  // Reset form data when country changes
  React.useEffect(() => {
    const currentCountry = props.compliance_info.is_business
      ? props.compliance_info.business_country
      : props.compliance_info.country;

    if (previousCountryRef.current !== currentCountry) {
      form.setData({
        user: props.compliance_info,
        payouts_paused_by_user: props.payouts_paused_by_user,
        payout_threshold_cents: props.payout_threshold_cents,
        payout_frequency: props.payout_frequency,
        bank_account: props.bank_account_details.bank_account,
        payment_address: props.paypal_address,
      });
      setErrorFieldNames(new Set());
      setClientErrorMessage(null);
      previousCountryRef.current = currentCountry;
    }
  }, [props.compliance_info.country, props.compliance_info.business_country]);

  // Sync showNewBankAccount when bank account details change (e.g., after successful save or country change)
  React.useEffect(() => {
    setShowNewBankAccount(!props.bank_account_details.account_number_visual);
  }, [props.bank_account_details.account_number_visual]);

  React.useEffect(() => {
    if ((errors?.base && errors.base.length > 0) || clientErrorMessage) {
      formRef.current?.scrollIntoView({ behavior: "smooth" });
    }
  }, [errors, clientErrorMessage]);

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
    return input && parsePhoneNumberFromString(input, countryCode)?.isValid();
  };

  const validateKanaField = (
    fieldName: FormFieldName,
    value: string | null | undefined,
    regex: RegExp,
    label: string,
    errorSuffix: string,
  ) => {
    if (value && !regex.test(value)) {
      markFieldInvalid(fieldName);
      setClientErrorMessage({ message: `${label} ${errorSuffix}` });
    }
  };

  const validateBankAccountFields = () => {
    if (!form.data.bank_account) {
      return;
    }

    if (!form.data.bank_account.account_holder_full_name) {
      markFieldInvalid("account_holder_full_name");
    }
    if (form.data.bank_account.type === "AchAccount" && !form.data.bank_account.routing_number) {
      markFieldInvalid("routing_number");
    }
    if (form.data.bank_account.type === "AustralianBankAccount" && !form.data.bank_account.bsb_number) {
      markFieldInvalid("bsb_number");
    }
    if (form.data.bank_account.type === "CanadianBankAccount" && !form.data.bank_account.transit_number) {
      markFieldInvalid("transit_number");
    }
    if (form.data.bank_account.type === "CanadianBankAccount" && !form.data.bank_account.institution_number) {
      markFieldInvalid("institution_number");
    }
    if (form.data.bank_account.type === "HongKongBankAccount" && !form.data.bank_account.clearing_code) {
      markFieldInvalid("clearing_code");
    }
    if (form.data.bank_account.type === "HongKongBankAccount" && !form.data.bank_account.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (form.data.bank_account.type === "KoreaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "PhilippinesBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "SingaporeanBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "SingaporeanBankAccount" && !form.data.bank_account.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (form.data.bank_account.type === "ThailandBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "TrinidadAndTobagoBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "TrinidadAndTobagoBankAccount" && !form.data.bank_account.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (
      (form.data.bank_account.type === "UkBankAccount" || form.data.bank_account.type === "GibraltarBankAccount") &&
      !form.data.bank_account.sort_code
    ) {
      markFieldInvalid("sort_code");
    }
    if (form.data.bank_account.type === "IndianBankAccount" && !form.data.bank_account.ifsc) {
      markFieldInvalid("ifsc");
    }
    if (form.data.bank_account.type === "VietnamBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "TaiwanBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "IndonesiaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "ChileBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "ChileBankAccount" && !form.data.bank_account.account_type) {
      markFieldInvalid("account_type");
    }
    if (form.data.bank_account.type === "PakistanBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "TurkeyBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "MoroccoBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "JapanBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "MalaysiaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "BosniaAndHerzegovinaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "JapanBankAccount" && !form.data.bank_account.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (form.data.bank_account.type === "BotswanaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "SerbiaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "SouthAfricaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "KenyaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "NorthMacedoniaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "EgyptBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "AntiguaAndBarbudaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "TanzaniaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "NamibiaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "EthiopiaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "BruneiBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "GuyanaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "GuatemalaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "ColombiaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "ColombiaBankAccount" && !form.data.bank_account.account_type) {
      markFieldInvalid("account_type");
    }
    if (form.data.bank_account.type === "SaudiArabiaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "UruguayBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "MauritiusBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "JamaicaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "JamaicaBankAccount" && !form.data.bank_account.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (form.data.bank_account.type === "EcuadorBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "KazakhstanBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "OmanBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "RwandaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "DominicanRepublicBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "UzbekistanBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "UzbekistanBankAccount" && !form.data.bank_account.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (form.data.bank_account.type === "BoliviaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("branch_code");
    }
    if (form.data.bank_account.type === "GhanaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "AlbaniaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "BahrainBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "JordanBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "NigeriaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "AngolaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "SanMarinoBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "AzerbaijanBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "AzerbaijanBankAccount" && !form.data.bank_account.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (form.data.bank_account.type === "MoldovaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "PanamaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "ElSalvadorBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "ParaguayBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "ArmeniaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "SriLankaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "SriLankaBankAccount" && !form.data.bank_account.branch_code) {
      markFieldInvalid("branch_code");
    }
    if (form.data.bank_account.type === "BangladeshBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "BhutanBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "LaosBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "MozambiqueBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "KuwaitBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "QatarBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "BahamasBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "SaintLuciaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "CambodiaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "MongoliaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "AlgeriaBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (form.data.bank_account.type === "MacaoBankAccount" && !form.data.bank_account.bank_code) {
      markFieldInvalid("bank_code");
    }
    if (!form.data.bank_account.account_number) {
      markFieldInvalid("account_number");
    }
    if (!form.data.bank_account.account_number_confirmation) {
      markFieldInvalid("account_number_confirmation");
    }
  };

  const validateComplianceInfoFields = () => {
    if (!form.data.user.first_name) {
      markFieldInvalid("first_name");
    }
    if (!form.data.user.last_name) {
      markFieldInvalid("last_name");
    }
    if (form.data.user.country === "JP") {
      if (!form.data.user.building_number) {
        markFieldInvalid("building_number");
      }
      if (!form.data.user.street_address_kanji) {
        markFieldInvalid("street_address_kanji");
      }
      if (!form.data.user.street_address_kana) {
        markFieldInvalid("street_address_kana");
      }
      validateKanaField(
        "first_name_kana",
        form.data.user.first_name_kana,
        KANA_NAME_REGEX,
        "First name (Kana)",
        KANA_NAME_ERROR,
      );
      validateKanaField(
        "last_name_kana",
        form.data.user.last_name_kana,
        KANA_NAME_REGEX,
        "Last name (Kana)",
        KANA_NAME_ERROR,
      );
      validateKanaField(
        "building_number_kana",
        form.data.user.building_number_kana,
        KANA_ADDRESS_REGEX,
        "Building number (Kana)",
        KANA_ADDRESS_ERROR,
      );
      validateKanaField(
        "street_address_kana",
        form.data.user.street_address_kana,
        KANA_ADDRESS_REGEX,
        "Street address (Kana)",
        KANA_ADDRESS_ERROR,
      );
    } else if (
      !form.data.user.street_address ||
      (form.data.user.country === "US" && isStreetAddressPOBox(form.data.user.street_address))
    ) {
      markFieldInvalid("street_address");
      if (form.data.user.street_address) {
        setClientErrorMessage({
          message: "We require a valid physical US address. We cannot accept a P.O. Box as a valid address.",
        });
      }
    }
    if (form.data.user.country !== "JP" && !form.data.user.city) {
      markFieldInvalid("city");
    }
    if (
      form.data.user.country !== null &&
      form.data.user.country.toLowerCase() in props.states &&
      !form.data.user.state
    ) {
      markFieldInvalid("state");
      setClientErrorMessage({ message: "Please select a valid state or province." });
    }
    if (!form.data.user.zip_code && form.data.user.country !== "BW") {
      markFieldInvalid("zip_code");
    }
    if (!validatePhoneNumber(form.data.user.phone, form.data.user.country)) {
      markFieldInvalid("phone");
      setClientErrorMessage({
        message: 'Please enter your full phone number, starting with a "+" and your country code.',
      });
    }
    if (form.data.user.dob_day === 0) {
      markFieldInvalid("dob_day");
    }
    if (form.data.user.dob_month === 0) {
      markFieldInvalid("dob_month");
    }
    if (form.data.user.dob_year === 0) {
      markFieldInvalid("dob_year");
    }
    if (
      form.data.user.country !== null &&
      form.data.user.country in props.user.individual_tax_id_needed_countries &&
      !props.user.individual_tax_id_entered &&
      !form.data.user.individual_tax_id
    ) {
      markFieldInvalid("individual_tax_id");
    }
    if (form.data.user.is_business) {
      if (!form.data.user.business_type) {
        markFieldInvalid("business_type");
      }
      if (!form.data.user.business_name) {
        markFieldInvalid("business_name");
      }
      if (form.data.user.business_country === "CA") {
        if (!form.data.user.job_title) {
          markFieldInvalid("job_title");
        }
      }
      if (form.data.user.business_country === "JP") {
        if (!form.data.user.business_name_kanji) {
          markFieldInvalid("business_name_kanji");
        }
        if (!form.data.user.business_name_kana) {
          markFieldInvalid("business_name_kana");
        }
        if (!form.data.user.business_building_number) {
          markFieldInvalid("business_building_number");
        }
        if (!form.data.user.business_street_address_kanji) {
          markFieldInvalid("business_street_address_kanji");
        }
        if (!form.data.user.business_street_address_kana) {
          markFieldInvalid("business_street_address_kana");
        }
        validateKanaField(
          "business_name_kana",
          form.data.user.business_name_kana,
          KANA_NAME_REGEX,
          "Business name (Kana)",
          KANA_NAME_ERROR,
        );
        validateKanaField(
          "business_building_number_kana",
          form.data.user.business_building_number_kana,
          KANA_ADDRESS_REGEX,
          "Business building number (Kana)",
          KANA_ADDRESS_ERROR,
        );
        validateKanaField(
          "business_street_address_kana",
          form.data.user.business_street_address_kana,
          KANA_ADDRESS_REGEX,
          "Business street address (Kana)",
          KANA_ADDRESS_ERROR,
        );
        if (form.data.user.business_name && HAS_JAPANESE_CHARS.test(form.data.user.business_name)) {
          markFieldInvalid("business_name");
          setClientErrorMessage({
            message: "Legal business name must be in romaji (latin characters) for Japanese accounts.",
          });
        }
      } else if (
        !form.data.user.business_street_address ||
        (form.data.user.business_country === "US" && isStreetAddressPOBox(form.data.user.business_street_address))
      ) {
        markFieldInvalid("business_street_address");
        if (form.data.user.business_street_address) {
          setClientErrorMessage({
            message: "We require a valid physical US address. We cannot accept a P.O. Box as a valid address.",
          });
        }
      }
      if (!form.data.user.business_city) {
        markFieldInvalid("business_city");
      }
      if (
        form.data.user.business_country !== null &&
        form.data.user.business_country.toLowerCase() in props.states &&
        !form.data.user.business_state
      ) {
        markFieldInvalid("business_state");
        setClientErrorMessage({ message: "Please select a valid state or province." });
      }
      if (!form.data.user.business_zip_code && props.user.country_code !== "BW") {
        markFieldInvalid("business_zip_code");
      }
      if (!validatePhoneNumber(form.data.user.business_phone, form.data.user.business_country)) {
        markFieldInvalid("business_phone");
        setClientErrorMessage({
          message: 'Please enter your full phone number, starting with a "+" and your country code.',
        });
      }
      if (
        (props.user.country_supports_native_payouts || form.data.user.business_country === "AE") &&
        !props.user.business_tax_id_entered &&
        !form.data.user.business_tax_id
      ) {
        markFieldInvalid("business_tax_id");
      }
    }
  };

  const validateForm = () => {
    setClientErrorMessage(null);

    if (isUpdateCountryConfirmed) {
      return true;
    }

    if (selectedPayoutMethod === "bank" && showNewBankAccount) {
      validateBankAccountFields();
    } else if (selectedPayoutMethod === "paypal" && !form.data.payment_address) {
      markFieldInvalid("paypal_email_address");
    }

    if (selectedPayoutMethod !== "stripe") {
      validateComplianceInfoFields();
    }

    return errorFieldNames.size === 0;
  };

  const handleSave = asyncVoid(async () => {
    if (!validateForm()) return;

    setClientErrorMessage(null);

    let cardData: CardPayoutToken | { stripe_error: unknown } | null = null;
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
      return;
    }

    form.transform((data) => {
      const transformed: Record<string, unknown> = {
        user: data.user,
        payouts_paused_by_user: data.payouts_paused_by_user,
        payout_threshold_cents: data.payout_threshold_cents,
        payout_frequency: data.payout_frequency,
      };

      if (selectedPayoutMethod === "bank") {
        transformed.bank_account = data.bank_account;
      } else if (selectedPayoutMethod === "card") {
        transformed.card = cardData;
      } else if (selectedPayoutMethod === "paypal") {
        transformed.payment_address = data.payment_address;
      }

      return transformed;
    });

    form.put(Routes.settings_payments_path(), {
      preserveScroll: true,
    });
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
  const updatedCountry = form.data.user.updated_country_code
    ? props.countries[form.data.user.updated_country_code]
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

  const payoutThresholdError =
    form.data.payout_threshold_cents != null && form.data.payout_threshold_cents < props.minimum_payout_threshold_cents;

  const handlePayoutThresholdBlur = () => {
    if (!form.data.payout_threshold_cents) {
      form.setData("payout_threshold_cents", props.minimum_payout_threshold_cents);
    }
  };

  const payoutsPausedToggle = (
    <Fieldset>
      <Switch
        checked={form.data.payouts_paused_by_user || props.payouts_paused_internally}
        onChange={(e) => form.setData("payouts_paused_by_user", e.target.checked)}
        aria-label="Pause payouts"
        disabled={props.is_form_disabled || props.payouts_paused_internally}
        label="Pause payouts"
      />
      <FieldsetDescription>
        By pausing payouts, they won't be processed until you decide to resume them, and your balance will remain in
        your account until then.
      </FieldsetDescription>
    </Fieldset>
  );

  return (
    <Layout
      currentPage="payments"
      pages={props.settings_pages}
      onSave={handleSave}
      canUpdate={!props.is_form_disabled && !form.processing && !payoutThresholdError}
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
          <Alert className="m-4 md:m-8" role="status" variant="warning">
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
          </Alert>
        ) : null}

        <FormSection header={<h2>Verification</h2>}>
          {props.show_verification_section ? (
            <StripeConnectEmbeddedNotificationBanner />
          ) : (
            <div className="flex flex-col">
              <Alert role="status" variant="success">
                Your identity has been verified!
              </Alert>
              <div className="mt-4 flex items-center">
                <img src={logo} alt="Gum Coin" className="mr-2 h-5 w-5" />
                <span className="text-sm text-muted">
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
        </FormSection>

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

        {(errors?.base && errors.base.length > 0) || clientErrorMessage ? (
          <div className="mb-12 px-8">
            <Alert variant="danger" role="status">
              {errors?.base && errors.base.length > 0 ? (
                errors.error_code?.[0] === "stripe_error" ? (
                  <div>Your account could not be updated due to an error with Stripe.</div>
                ) : (
                  errors.base[0]
                )
              ) : clientErrorMessage ? (
                clientErrorMessage.message
              ) : null}
            </Alert>
          </div>
        ) : null}
        <FormSection
          header={
            <>
              <h2>Payout schedule</h2>
              <p>
                Payouts will only happen on your chosen schedule once the minimum balance of{" "}
                {formatPriceCentsWithCurrencySymbol("usd", props.minimum_payout_threshold_cents, {
                  symbolFormat: "long",
                })}{" "}
                is reached.
              </p>
            </>
          }
        >
          <section className="flex flex-col gap-4">
            <Fieldset>
              <Label htmlFor="payout_frequency">Schedule</Label>
              <TypeSafeOptionSelect
                id="payout_frequency"
                name="Schedule"
                value={form.data.payout_frequency}
                onChange={(value) => form.setData("payout_frequency", value)}
                options={PAYOUT_FREQUENCIES.map((frequency) => ({
                  id: frequency,
                  label: frequency.charAt(0).toUpperCase() + frequency.slice(1),
                  disabled: frequency === "daily" && !props.payout_frequency_daily_supported,
                }))}
              />
              <FieldsetDescription>
                Daily payouts are only available for US users with eligible bank accounts and more than 4 previous
                payouts.
              </FieldsetDescription>
            </Fieldset>
            {form.data.payout_frequency === "daily" && props.payout_frequency_daily_supported ? (
              <Alert variant="info" role="status">
                <div>
                  Every day, your balance from the previous day will be sent to you via instant payouts, subject to a{" "}
                  <b>3% fee</b>.
                </div>
              </Alert>
            ) : null}
            {form.data.payout_frequency === "daily" && !props.payout_frequency_daily_supported && (
              <Alert variant="danger" role="status">
                <div>Your account is no longer eligible for daily payouts. Please update your schedule.</div>
              </Alert>
            )}
            <Fieldset state={payoutThresholdError ? "danger" : undefined}>
              <Label htmlFor="payout_threshold_cents">Minimum payout threshold</Label>
              <PriceInput
                id="payout_threshold_cents"
                currencyCode="usd"
                cents={form.data.payout_threshold_cents}
                disabled={props.is_form_disabled}
                onChange={(value) => form.setData("payout_threshold_cents", value)}
                onBlur={handlePayoutThresholdBlur}
                placeholder={formatPriceCentsWithoutCurrencySymbol("usd", props.minimum_payout_threshold_cents)}
                ariaLabel="Minimum payout threshold"
                hasError={!!payoutThresholdError}
              />
              <FieldsetDescription>
                The minimum payout threshold for {props.payout_country_name ?? "your country"} is{" "}
                {formatPriceCentsWithCurrencySymbol("usd", props.minimum_payout_threshold_cents, {
                  symbolFormat: "long",
                })}
                .
              </FieldsetDescription>
            </Fieldset>
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
        </FormSection>

        <FormSection
          header={
            <>
              <h2>Payout method</h2>
              <div>
                <a href="/help/article/260-your-payout-settings-page" target="_blank" rel="noreferrer">
                  Any questions about these payout settings?
                </a>
              </div>
            </>
          }
        >
          <section className="grid gap-8">
            <Tabs variant="buttons" className="gap-4" role="radiogroup">
              {props.bank_account_details.show_bank_account ? (
                <>
                  <Tab key="bank" isSelected={selectedPayoutMethod === "bank"} asChild>
                    <Button
                      role="radio"
                      aria-checked={selectedPayoutMethod === "bank"}
                      onClick={() => updatePayoutMethod("bank")}
                      disabled={props.is_form_disabled}
                      className="items-start justify-start text-left"
                    >
                      <Icon name="bank" />
                      <div>
                        <h4 className="font-bold">Bank Account</h4>
                      </div>
                    </Button>
                  </Tab>
                  {props.user.country_code === "US" ? (
                    <Tab key="card" isSelected={selectedPayoutMethod === "card"} asChild>
                      <Button
                        role="radio"
                        aria-checked={selectedPayoutMethod === "card"}
                        onClick={() => updatePayoutMethod("card")}
                        disabled={props.is_form_disabled}
                        className="items-start justify-start text-left"
                      >
                        <Icon name="card" />
                        <div>
                          <h4 className="font-bold">Debit Card</h4>
                        </div>
                      </Button>
                    </Tab>
                  ) : null}
                </>
              ) : null}
              {props.bank_account_details.show_paypal ? (
                <Tab key="paypal" isSelected={selectedPayoutMethod === "paypal"} asChild>
                  <Button
                    role="radio"
                    aria-checked={selectedPayoutMethod === "paypal"}
                    onClick={() => updatePayoutMethod("paypal")}
                    disabled={props.is_form_disabled}
                    className="items-start justify-start text-left"
                  >
                    <Icon name="shop-window" />
                    <div>
                      <h4 className="font-bold">PayPal</h4>
                    </div>
                  </Button>
                </Tab>
              ) : null}
              {props.user.country_code === "BR" ||
              props.user.can_connect_stripe ||
              props.stripe_connect.has_connected_stripe ? (
                <Tab key="stripe" isSelected={selectedPayoutMethod === "stripe"} asChild>
                  <Button
                    role="radio"
                    aria-checked={selectedPayoutMethod === "stripe"}
                    onClick={() => updatePayoutMethod("stripe")}
                    disabled={props.is_form_disabled}
                    className="items-start justify-start text-left"
                  >
                    <Icon name="stripe" />
                    <div>
                      <h4 className="font-bold">Connect to Stripe</h4>
                    </div>
                  </Button>
                </Tab>
              ) : null}
            </Tabs>
            {selectedPayoutMethod === "bank" ? (
              <BankAccountSection
                bankAccountDetails={props.bank_account_details}
                bankAccount={form.data.bank_account}
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
                paypalEmailAddress={form.data.payment_address}
                setPaypalEmailAddress={(value) => form.setData("payment_address", value)}
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
                complianceInfo={form.data.user}
                updateComplianceInfo={updateComplianceInfo}
                minDobYear={props.min_dob_year}
                isFormDisabled={props.is_form_disabled}
                countries={props.countries}
                uaeBusinessTypes={props.uae_business_types}
                indiaBusinessTypes={props.india_business_types}
                canadaBusinessTypes={props.canada_business_types}
                states={props.states}
                errorFieldNames={errorFieldNames}
              />
            ) : (
              <StripeConnectSection
                stripeConnect={props.stripe_connect}
                isFormDisabled={props.is_form_disabled}
                connectAccountFeeInfoText={props.fee_info.connect_account_fee_info_text}
              />
            )}
          </section>
        </FormSection>
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
}
