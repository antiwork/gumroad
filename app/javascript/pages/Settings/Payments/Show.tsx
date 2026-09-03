import { Bank, CreditCard, Paypal, Stripe } from "@boxicons/react";
import { router, useForm, usePage } from "@inertiajs/react";
import parsePhoneNumberFromString, { CountryCode } from "libphonenumber-js";
import * as React from "react";
import typia from "typia";

import { CardPayoutError, prepareCardTokenForPayouts, type CardPayoutToken } from "$app/data/card_payout_data";
import { SavedCreditCard } from "$app/parsers/card";
import { SettingPage } from "$app/parsers/settings";
import type { ComplianceInfo, PayoutMethod, FormFieldName, User, PayoutDebitCardData } from "$app/types/payments";
import { COLOMBIA_ID_NUMBER_ERROR_MESSAGE, isValidColombiaIdNumber } from "$app/utils/colombiaIdNumbers";
import { formatPriceCentsWithCurrencySymbol, formatPriceCentsWithoutCurrencySymbol } from "$app/utils/currency";
import { accountNumberFormatError } from "$app/utils/payoutAccountNumbers";
import { countryRequiresPostalCode } from "$app/utils/postalCodes";
import { asyncVoid } from "$app/utils/promise";

import { Button } from "$app/components/Button";
import { ConfirmBalanceForfeitOnPayoutMethodChangeModal } from "$app/components/ConfirmBalanceForfeitOnPayoutMethodChangeModal";
import { CountrySelectionModal } from "$app/components/CountrySelectionModal";
import { PriceInput } from "$app/components/PriceInput";
import { CreditCardForm } from "$app/components/Settings/AdvancedPage/CreditCardForm";
import { Layout } from "$app/components/Settings/Layout";
import AccountDetailsSection from "$app/components/Settings/PaymentsPage/AccountDetailsSection";
import AccountStatusSection, { type AccountStatus } from "$app/components/Settings/PaymentsPage/AccountStatusSection";
import AusBackTaxesSection, { type AusBacktaxDetails } from "$app/components/Settings/PaymentsPage/AusBackTaxesSection";
import BankAccountSection, {
  BankAccountDetails,
  type BankAccount,
} from "$app/components/Settings/PaymentsPage/BankAccountSection";
import BeneficialOwnersSection from "$app/components/Settings/PaymentsPage/BeneficialOwnersSection";
import DebitCardSection from "$app/components/Settings/PaymentsPage/DebitCardSection";
import LegalGuardianSection, {
  type LegalGuardianProps,
} from "$app/components/Settings/PaymentsPage/LegalGuardianSection";
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
import { WithTooltip } from "$app/components/WithTooltip";

const KANA_NAME_REGEX = /^[\u30A0-\u30FF\u31F0-\u31FF\uFF65-\uFF9F\s\-.]*$/u;
const KANA_ADDRESS_REGEX = /^[\u30A0-\u30FF\u31F0-\u31FF\uFF65-\uFF9F\p{Script=Latin}\d\s\-.]*$/u;

// GambiaBankAccount's bank code is a SWIFT/BIC of 8 to 11 letters or digits
// (/^[0-9A-Za-z]{8,11}$/), e.g. AGIXGMGM. The input carries a matching `pattern`, but the Save
// button runs this page's own validation and posts through Inertia rather than submitting the form
// element, so the browser never enforces that pattern. Re-check the shape here so a malformed code
// is caught before the request goes out instead of coming back as a generic "The bank code is
// invalid." from the server.
const GAMBIA_SWIFT_BIC_REGEX = /^[0-9A-Za-z]{8,11}$/u;

// Same reason as Gambia above: the input's `pattern` is never enforced, and `maxLength` cannot see
// the difference between `014` and `BCA`. Stripe resolves the ID bank from its 3-digit Sandi Bank
// directory, so a letter code saves here and then fails bank-sync with routing_number_invalid.
const INDONESIA_BANK_CODE_REGEX = /^[0-9]{3}$/u;

const KANA_NAME_ERROR = "may only contain katakana characters, spaces, dashes, and dots.";
const KANA_ADDRESS_ERROR = "may only contain katakana, latin characters, digits, spaces, dashes, and dots.";

const HAS_JAPANESE_CHARS = /[\u3000-\u303F\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\uFF65-\uFF9F]/u;
const HAS_KATAKANA = /[\u30A0-\u30FF\u31F0-\u31FF\uFF65-\uFF9F]/u;

const PAYOUT_FREQUENCIES = ["daily", "weekly", "monthly", "quarterly"] as const;

// Human-readable names for every field the client-side validation can reject, so a failed save
// can tell the seller exactly which fields are blocking it. Without this the only signal was a red
// outline on the field itself, which is normally scrolled off-screen: the save button lives in the
// sticky header at the top of the page while the compliance and bank fields sit far below the fold,
// so sellers pressed "Update settings", saw nothing happen, and reported the button as dead. See
// antiwork/gumroad-private#1388.
const FIELD_LABELS: Record<FormFieldName, string> = {
  first_name: "First name",
  last_name: "Last name",
  first_name_kanji: "First name (Kanji)",
  last_name_kanji: "Last name (Kanji)",
  first_name_kana: "First name (Kana)",
  last_name_kana: "Last name (Kana)",
  building_number: "Block / Building number",
  building_number_kana: "Block / Building number (Kana)",
  street_address_kanji: "Town/Cho-me (Kanji)",
  street_address_kana: "Town/Cho-me (Kana)",
  street_address: "Address",
  city: "City",
  city_kana: "City (Kana)",
  state: "State or province",
  zip_code: "Postal code",
  dob_year: "Date of birth",
  dob_month: "Date of birth",
  dob_day: "Date of birth",
  phone: "Phone number",
  nationality: "Nationality",
  individual_tax_id: "Tax ID",
  business_type: "Business type",
  business_name: "Legal business name",
  business_name_kanji: "Business name (Kanji)",
  business_name_kana: "Business name (Kana)",
  business_street_address: "Business address",
  business_building_number: "Business block / building number",
  business_building_number_kana: "Business block / building number (Kana)",
  business_street_address_kanji: "Business town/Cho-me (Kanji)",
  business_street_address_kana: "Business town/Cho-me (Kana)",
  business_city: "Business city",
  business_city_kana: "Business city (Kana)",
  business_state: "Business state or province",
  business_zip_code: "Business postal code",
  business_phone: "Business phone number",
  job_title: "Job title",
  business_tax_id: "Business tax ID",
  routing_number: "Routing number",
  transit_number: "Transit number",
  institution_number: "Institution number",
  bsb_number: "BSB number",
  bank_code: "Bank code",
  branch_code: "Branch code",
  clearing_code: "Clearing code",
  sort_code: "Sort code",
  ifsc: "IFSC",
  account_type: "Account type",
  account_holder_full_name: "Pay to the order of",
  account_number: "Account number",
  account_number_confirmation: "Confirm account number",
  paypal_email_address: "PayPal email address",
};

const missingFieldsErrorMessage = (fieldNames: Set<FormFieldName>) => {
  // Deduplicate labels: the three date-of-birth inputs share one label, and several country-specific
  // bank fields reuse the same one too.
  const labels = [...new Set([...fieldNames].map((fieldName) => FIELD_LABELS[fieldName]))];
  if (labels.length === 0) return null;
  return `Please complete the required fields below: ${labels.join(", ")}.`;
};

// Names the invalid fields from the labels actually rendered next to them, so the banner matches
// what the seller is looking at. Several labels change with the seller's country — a US seller sees
// "ZIP code" where everyone else sees "Postal code", and the state field is variously labelled
// State, Province, County or Prefecture — so a hardcoded list would name a field they cannot find.
// Falls back to FIELD_LABELS for any input with no label element, and always uses it for the three
// date-of-birth selects, whose own labels ("Month", "Day", "Year") only make sense together.
const missingFieldsErrorMessageFromDom = (form: HTMLElement, fieldNames: Set<FormFieldName>) => {
  const labels: string[] = [];
  let usedDobLabel = false;

  for (const field of form.querySelectorAll<HTMLElement>('[aria-invalid="true"]')) {
    if (field.id.includes("-dob-")) {
      if (usedDobLabel) continue;
      usedDobLabel = true;
      labels.push(FIELD_LABELS.dob_year);
      continue;
    }
    const label = field.id ? form.querySelector(`label[for="${CSS.escape(field.id)}"]`) : null;
    const text = label?.textContent?.trim();
    if (text) labels.push(text);
  }

  const deduplicated = [...new Set(labels)];
  // No labelled invalid inputs in the DOM (a field rendered without a label, or an error that isn't
  // tied to a visible input) — fall back to the curated names so the banner still says something.
  if (deduplicated.length === 0) return missingFieldsErrorMessage(fieldNames);
  return `Please complete the required fields below: ${deduplicated.join(", ")}.`;
};

const PERU_DNI_DIGIT_COUNT = 9;
const FULL_SSN_DIGIT_COUNT = 9;
// A Singapore NRIC/FIN is a leading letter (S/T/F/G/M), seven digits, and a trailing checksum
// letter — e.g. S1234567A. Mirrors the authoritative server-side check in
// UpdateUserComplianceInfo; this one just gives the seller fast inline feedback.
const SINGAPORE_NRIC_FIN_REGEX = /^[STFGM]\d{7}[A-Z]$/iu;
type PayoutFrequency = (typeof PAYOUT_FREQUENCIES)[number];

type PaymentsPageProps = {
  settings_pages: SettingPage[];
  is_form_disabled: boolean;
  should_show_country_modal: boolean;
  aus_backtax_details: AusBacktaxDetails & {
    show_au_backtax_prompt: boolean;
  };
  countries: Record<string, string>;
  ip_country_code: string | null;
  bank_account_details: BankAccountDetails;
  paypal_address: string | null;
  stripe_connect: StripeConnect;
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
  payout_reserve_percent?: number | null;
  account_status: AccountStatus;
  payouts_paused_by_user: boolean;
  payout_threshold_cents: number;
  minimum_payout_threshold_cents: number;
  payout_country_name: string | null;
  payout_frequency: PayoutFrequency;
  payout_frequency_daily_supported: boolean;
  instant_payout_fee_percent: number;
  buyer_local_currency_enabled: boolean;
  disable_buyer_local_currency: boolean;
  buyer_currency_charging_enabled: boolean;
  disable_buyer_currency_rounding: boolean;
  can_manage_beneficial_owners: boolean;
  legal_guardian: LegalGuardianProps;
  errors?: {
    base?: string[];
  };
};

type ErrorMessageInfo = {
  message: string;
  code?: string | null;
};

export default function PaymentsPage() {
  const page = usePage();
  const props = typia.assert<PaymentsPageProps>(page.props);
  const errors = typia.assert<{ base?: string[] } | undefined>(page.props.errors);

  const [clientErrorMessage, setClientErrorMessage] = React.useState<ErrorMessageInfo | null>(null);
  const formRef = React.useRef<HTMLDivElement & HTMLFormElement>(null);
  const [errorFieldNames, setErrorFieldNames] = React.useState(() => new Set<FormFieldName>());
  // The authoritative set of fields the current validation pass has rejected. It lives in a ref as
  // well as in state because validateForm both writes it (through markFieldInvalid, from a dozen
  // nested helpers) and reads it back within the same synchronous call, before React has re-rendered.
  const errorFieldNamesRef = React.useRef(errorFieldNames);
  const resetErrorFieldNames = () => {
    errorFieldNamesRef.current = new Set();
    setErrorFieldNames(errorFieldNamesRef.current);
  };
  // Counts failed save attempts. The scroll-to-first-invalid-field effect keys off this rather than
  // off errorFieldNames, so it fires once per press of "Update settings" and never again while the
  // seller is typing their way through the fields it pointed them at.
  const [failedSaveAttempts, setFailedSaveAttempts] = React.useState(0);
  const markFieldInvalid = (fieldName: FormFieldName) => {
    errorFieldNamesRef.current = new Set(errorFieldNamesRef.current).add(fieldName);
    setErrorFieldNames(errorFieldNamesRef.current);
  };
  const [isUpdateCountryConfirmed, setIsUpdateCountryConfirmed] = React.useState(false);
  const [isPayoutMethodChangeConfirmed, setIsPayoutMethodChangeConfirmed] = React.useState(false);
  const [saveCounter, setSaveCounter] = React.useState(0);

  const form = useForm<{
    user: ComplianceInfo;
    payouts_paused_by_user: boolean;
    payout_threshold_cents: number | null;
    payout_frequency: PayoutFrequency;
    disable_buyer_local_currency: boolean;
    disable_buyer_currency_rounding: boolean;
    bank_account: Partial<BankAccount> | null;
    payment_address: string | null;
  }>({
    user: props.compliance_info,
    payouts_paused_by_user: props.payouts_paused_by_user,
    payout_threshold_cents: props.payout_threshold_cents,
    payout_frequency: props.payout_frequency,
    disable_buyer_local_currency: props.disable_buyer_local_currency,
    disable_buyer_currency_rounding: props.disable_buyer_currency_rounding,
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
    resetErrorFieldNames();
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
    resetErrorFieldNames();
  };

  const updateBankAccount = (newBankAccount: Partial<BankAccount>) => {
    form.setData("bank_account", { ...form.data.bank_account, ...newBankAccount });
    resetErrorFieldNames();
  };

  const [debitCard, setDebitCard] = React.useState<PayoutDebitCardData | null>(null);

  // The guardian is added by its own endpoint, not by this page's form, so the page's own props go
  // stale the moment it saves. Reloading only `legal_guardian` is what refreshes them — and the
  // reason not to merge the endpoint's response into local state instead is `blocking_payouts`: it
  // is derived server-side from the same predicate the payout gate reads, and recomputing it here
  // would let the page tell a seller their payouts are running while Payouts.is_user_payable
  // disagrees.
  const refreshLegalGuardian = () => router.reload({ only: ["legal_guardian"] });

  // The guardian is a person on the seller's own payout account, so they are in the seller's country
  // and pick from its subdivisions. Empty for a country with no subdivision list, which is what
  // hides the field — the guardian path is US-only today, so in practice this is always the US list.
  const guardianStates = React.useMemo(() => {
    switch (props.user.country_code) {
      case "US":
        return props.states.us;
      case "CA":
        return props.states.ca;
      case "AU":
        return props.states.au;
      case "MX":
        return props.states.mx;
      case "AE":
        return props.states.ae;
      case "IE":
        return props.states.ir;
      case "BR":
        return props.states.br;
      default:
        return [];
    }
  }, [props.user.country_code, props.states]);

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
        disable_buyer_local_currency: props.disable_buyer_local_currency,
        disable_buyer_currency_rounding: props.disable_buyer_currency_rounding,
        bank_account: props.bank_account_details.bank_account,
        payment_address: props.paypal_address,
      });
      resetErrorFieldNames();
      setClientErrorMessage(null);
      previousCountryRef.current = currentCountry;
    }
  }, [props.compliance_info.country, props.compliance_info.business_country]);

  // Sync showNewBankAccount when bank account details change (e.g., after successful save or country change)
  React.useEffect(() => {
    setShowNewBankAccount(!props.bank_account_details.account_number_visual);
  }, [props.bank_account_details.account_number_visual]);

  React.useEffect(() => {
    const hasServerError = Boolean(errors?.base && errors.base.length > 0);
    // failedSaveAttempts only ever increments on a client-side validation failure, so a non-zero
    // value here means the last press of "Update settings" was rejected before it left the browser.
    if (!hasServerError && !clientErrorMessage && failedSaveAttempts === 0) return;

    // The individual checks in validateForm set a specific message for the cases they know about
    // (P.O. Box address, phone format, Kana character sets, and so on). When none of them did, fill
    // in a generic list of the fields that are blocking the save, read from the labels next to them.
    if (!hasServerError && !clientErrorMessage && formRef.current) {
      const message = missingFieldsErrorMessageFromDom(formRef.current, errorFieldNames);
      if (message) setClientErrorMessage({ message });
    }

    // Prefer scrolling to the first field that actually failed validation — the seller needs to see
    // the input, not just the banner at the top of the form. Falls back to the form itself for
    // server-side errors that aren't tied to a specific field.
    //
    // This deliberately keys off failedSaveAttempts rather than the set of invalid fields. Typing in
    // any field clears that set (see updateComplianceInfo), which would re-run this effect with no
    // invalid field left and scroll the seller back to the top of the form mid-keystroke — away from
    // the very field the banner just told them to fill in.
    const firstInvalidField = formRef.current?.querySelector<HTMLElement>('[aria-invalid="true"]');
    if (firstInvalidField) {
      firstInvalidField.scrollIntoView({ behavior: "smooth", block: "center" });
      firstInvalidField.focus({ preventScroll: true });
    } else {
      formRef.current?.scrollIntoView({ behavior: "smooth" });
    }
    // errorFieldNames is deliberately NOT a dependency — see the comment above.
  }, [errors, clientErrorMessage, failedSaveAttempts]);

  const isStreetAddressPOBox = (input: string) =>
    input
      .replace(/[^\w]*/gu, "")
      .toLocaleLowerCase()
      .includes("pobox");

  const poBoxAddressErrorMessage = (countryCode: CountryCode) => {
    if (countryCode === "US") {
      return "We require a valid physical US address. We cannot accept a P.O. Box as a valid address.";
    }

    if (countryCode === "GH") {
      return "We require a valid physical address in Ghana. We cannot accept a P.O. Box as a valid address.";
    }

    return "We require a valid physical address. We cannot accept a P.O. Box as a valid address.";
  };

  const countryRequiresPhysicalAddress = (countryCode: CountryCode) => ["US", "GH"].includes(countryCode);

  const isPhysicalAddressRequiredAndPOBox = (countryCode: CountryCode, input: string) =>
    countryRequiresPhysicalAddress(countryCode) && isStreetAddressPOBox(input);

  const validatePhoneNumber = (input: string | null, country_code: string | null) => {
    const countryCode: CountryCode = typia.assert<CountryCode>(country_code);
    // Use isPossible() (length/structure) rather than isValid() (exact allocated-range
    // membership). isValid() depends on bundled libphonenumber-js metadata that lags the
    // real numbering plan, so legitimately-allocated numbers in newly-added ranges (e.g.
    // AU 0494 6x) get wrongly rejected. Stripe performs the authoritative KYC validation
    // downstream. See antiwork/gumroad-private#733.
    return input && parsePhoneNumberFromString(input, countryCode)?.isPossible();
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
    if (form.data.bank_account.type === "IndonesiaBankAccount") {
      if (!form.data.bank_account.bank_code) {
        markFieldInvalid("bank_code");
      } else if (!INDONESIA_BANK_CODE_REGEX.test(form.data.bank_account.bank_code)) {
        markFieldInvalid("bank_code");
        setClientErrorMessage({ message: "Enter your bank's 3-digit Indonesian bank code, digits only." });
      }
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
    if (form.data.bank_account.type === "GuyanaBankAccount" && !form.data.bank_account.branch_code) {
      markFieldInvalid("branch_code");
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
    if (form.data.bank_account.type === "GambiaBankAccount") {
      if (!form.data.bank_account.bank_code) {
        markFieldInvalid("bank_code");
      } else if (!GAMBIA_SWIFT_BIC_REGEX.test(form.data.bank_account.bank_code)) {
        markFieldInvalid("bank_code");
        setClientErrorMessage({ message: "SWIFT / BIC code must be 8 to 11 letters or digits." });
      }
    }
    if (!form.data.bank_account.account_number) {
      markFieldInvalid("account_number");
    } else {
      // The account-number inputs advertise a per-country `pattern`, but the browser never enforces
      // it here (this page posts through Inertia instead of submitting the form), so run the same
      // check ourselves. Countries with no entry in the hints table fall through to the server.
      const formatError = accountNumberFormatError(props.user.country_code, form.data.bank_account.account_number);
      if (formatError) {
        markFieldInvalid("account_number");
        setClientErrorMessage({ message: formatError });
      }
    }
    if (!form.data.bank_account.account_number_confirmation) {
      markFieldInvalid("account_number_confirmation");
    }
  };

  const validateComplianceInfoFields = () => {
    const streetAddressValidationContextChanged =
      form.data.user.street_address !== props.compliance_info.street_address ||
      form.data.user.country !== props.compliance_info.country ||
      form.data.user.is_business !== props.compliance_info.is_business;
    const businessStreetAddressValidationContextChanged =
      form.data.user.business_street_address !== props.compliance_info.business_street_address ||
      form.data.user.business_country !== props.compliance_info.business_country ||
      form.data.user.is_business !== props.compliance_info.is_business;

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
      if (!form.data.user.city) {
        markFieldInvalid("city");
      }
      if (!form.data.user.city_kana) {
        markFieldInvalid("city_kana");
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
      validateKanaField(
        "street_address_kana",
        form.data.user.street_address_kana,
        HAS_KATAKANA,
        "Street address (Kana)",
        "must include katakana characters.",
      );
      validateKanaField("city_kana", form.data.user.city_kana, KANA_ADDRESS_REGEX, "City (Kana)", KANA_ADDRESS_ERROR);
      validateKanaField(
        "city_kana",
        form.data.user.city_kana,
        HAS_KATAKANA,
        "City (Kana)",
        "must include katakana characters.",
      );
    } else if (
      !form.data.user.street_address ||
      (streetAddressValidationContextChanged &&
        form.data.user.country !== null &&
        isPhysicalAddressRequiredAndPOBox(
          typia.assert<CountryCode>(form.data.user.country),
          form.data.user.street_address,
        ))
    ) {
      markFieldInvalid("street_address");
      if (form.data.user.street_address) {
        setClientErrorMessage({
          message: poBoxAddressErrorMessage(typia.assert<CountryCode>(form.data.user.country)),
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
    if (!form.data.user.zip_code && countryRequiresPostalCode(form.data.user.country)) {
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
      // Note: `in` tests object keys, and an array's keys are its indexes, so this branch never
      // matches a country code and the check is effectively inert. Switching it to includes() is a
      // behavior change, not a cleanup: it starts blocking saves the server still accepts (a KZ
      // PayPal payout needs no tax ID), so it needs its own change with the server rule aligned.
      form.data.user.country in props.user.individual_tax_id_needed_countries &&
      !props.user.individual_tax_id_entered &&
      !form.data.user.individual_tax_id
    ) {
      markFieldInvalid("individual_tax_id");
    }
    // Stripe's id_number requirement follows the account country — business_country for
    // businesses (same rule as the Peru DNI check below).
    const ssnRequirementCountry = form.data.user.is_business ? form.data.user.business_country : form.data.user.country;
    if (props.user.has_outstanding_full_ssn_requirement && ssnRequirementCountry === "US") {
      const typedSsnDigits = (form.data.user.individual_tax_id ?? "").replace(/\D/gu, "");
      // Only last-4 (or nothing) on file can never satisfy Stripe's id_number requirement, so the
      // seller must type a fresh full SSN; and any newly typed value must itself be 9 digits so a
      // fresh 4-digit entry can't be saved into a full-SSN requirement.
      const mustReenterFullSsn = props.user.individual_tax_id_is_last_four || !props.user.individual_tax_id_entered;
      if ((mustReenterFullSsn || form.data.user.individual_tax_id) && typedSsnDigits.length !== FULL_SSN_DIGIT_COUNT) {
        markFieldInvalid("individual_tax_id");
        setClientErrorMessage({
          message: "Our payments provider requires your full 9-digit Social Security Number.",
        });
      }
    }
    const peruDniRequired = form.data.user.is_business
      ? form.data.user.business_country === "PE"
      : form.data.user.country === "PE";
    if (
      peruDniRequired &&
      form.data.user.individual_tax_id &&
      form.data.user.individual_tax_id.replace(/\D/gu, "").length !== PERU_DNI_DIGIT_COUNT
    ) {
      markFieldInvalid("individual_tax_id");
      setClientErrorMessage({
        message: "Your DNI must include the verification digit (for example, 12345678-9).",
      });
    }
    const singaporeNricRequired = form.data.user.is_business
      ? form.data.user.business_country === "SG"
      : form.data.user.country === "SG";
    if (
      singaporeNricRequired &&
      form.data.user.individual_tax_id &&
      !SINGAPORE_NRIC_FIN_REGEX.test(form.data.user.individual_tax_id.replace(/[\s-]/gu, ""))
    ) {
      markFieldInvalid("individual_tax_id");
      setClientErrorMessage({
        message:
          "Your NRIC/FIN must start with S, T, F, G or M and end with a letter (for example, S1234567A). Please enter it exactly as it appears on your ID.",
      });
    }
    const colombiaIdRequired = form.data.user.is_business
      ? form.data.user.business_country === "CO"
      : form.data.user.country === "CO";
    if (
      colombiaIdRequired &&
      form.data.user.individual_tax_id &&
      !isValidColombiaIdNumber(form.data.user.individual_tax_id)
    ) {
      markFieldInvalid("individual_tax_id");
      setClientErrorMessage({ message: COLOMBIA_ID_NUMBER_ERROR_MESSAGE });
    }
    if (form.data.user.is_business) {
      if (!form.data.user.business_type) {
        markFieldInvalid("business_type");
      }
      if (!form.data.user.business_name) {
        markFieldInvalid("business_name");
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
        if (!form.data.user.business_city) {
          markFieldInvalid("business_city");
        }
        if (!form.data.user.business_city_kana) {
          markFieldInvalid("business_city_kana");
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
        validateKanaField(
          "business_street_address_kana",
          form.data.user.business_street_address_kana,
          HAS_KATAKANA,
          "Business street address (Kana)",
          "must include katakana characters.",
        );
        validateKanaField(
          "business_city_kana",
          form.data.user.business_city_kana,
          KANA_ADDRESS_REGEX,
          "Business city (Kana)",
          KANA_ADDRESS_ERROR,
        );
        validateKanaField(
          "business_city_kana",
          form.data.user.business_city_kana,
          HAS_KATAKANA,
          "Business city (Kana)",
          "must include katakana characters.",
        );
        if (form.data.user.business_name && HAS_JAPANESE_CHARS.test(form.data.user.business_name)) {
          markFieldInvalid("business_name");
          setClientErrorMessage({
            message: "Legal business name must be in romaji (latin characters) for Japanese accounts.",
          });
        }
      } else if (
        !form.data.user.business_street_address ||
        (businessStreetAddressValidationContextChanged &&
          form.data.user.business_country !== null &&
          isPhysicalAddressRequiredAndPOBox(
            typia.assert<CountryCode>(form.data.user.business_country),
            form.data.user.business_street_address,
          ))
      ) {
        markFieldInvalid("business_street_address");
        if (form.data.user.business_street_address) {
          setClientErrorMessage({
            message: poBoxAddressErrorMessage(typia.assert<CountryCode>(form.data.user.business_country)),
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
      if (!form.data.user.business_zip_code && countryRequiresPostalCode(props.user.country_code)) {
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
    // Start from a clean slate every attempt. Not every input clears the set as it changes (the
    // PayPal email field and the saved-bank-account toggle don't), so a leftover entry from a
    // previous attempt would otherwise block a save and name a field the seller has since filled in.
    resetErrorFieldNames();

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

    if (errorFieldNamesRef.current.size === 0) return true;

    // Some individual checks above (P.O. Box address, phone format, Kana character sets, and so on)
    // already set a specific message explaining what is wrong. The effect below fills in a generic
    // "these fields are missing" list when none of them did, so the save always says something.
    setFailedSaveAttempts((count) => count + 1);

    return false;
  };

  const handleSave = asyncVoid(async () => {
    if (!validateForm()) return;

    setClientErrorMessage(null);
    // The save is going out, so the previous failed attempt is no longer what the page is showing.
    setFailedSaveAttempts(0);

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
        disable_buyer_local_currency: data.disable_buyer_local_currency,
        disable_buyer_currency_rounding: data.disable_buyer_currency_rounding,
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
      onSuccess: () => setSaveCounter((counter) => counter + 1),
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
        <AccountStatusSection
          accountStatus={props.account_status}
          payoutsPausedBy={props.payouts_paused_by}
          payoutReservePercent={props.payout_reserve_percent}
        />

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

        {/* The banner uses the same padding as every FormSection on this page (see
            components/ui/FormSection.tsx), so it lines up with the form fields below it and keeps an
            even gap on all four sides. The old `mb-12 px-8` left it flush against the tabs above and
            inset further than the content on mobile. */}
        {(errors?.base && errors.base.length > 0) || clientErrorMessage ? (
          <div className="p-4! md:p-8!">
            <Alert variant="danger" role="status">
              {errors?.base?.[0] ?? clientErrorMessage?.message}
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
                  <b>{props.instant_payout_fee_percent}% fee</b> — the same fee as a one-off instant payout.
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
                    ? "Your payouts have been paused by Stripe."
                    : props.payouts_paused_by === "admin"
                      ? "Your payouts have been paused by Gumroad."
                      : props.payouts_paused_by === "system" && props.payout_reserve_percent
                        ? `We're holding ${props.payout_reserve_percent}% of your balance in reserve while your chargeback rate is above 1.5%. The rest pays out on the normal weekly schedule.`
                        : props.payouts_paused_by === "system"
                          ? "Your payouts have been paused for a security review."
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

        {props.buyer_local_currency_enabled ? (
          <FormSection header={<h2>Product pages</h2>}>
            <Fieldset>
              <Switch
                checked={!form.data.disable_buyer_local_currency}
                onChange={(e) => form.setData("disable_buyer_local_currency", !e.target.checked)}
                aria-label="Show buyers their local currency on product pages"
                disabled={props.is_form_disabled}
                label="Show buyers their local currency on product pages"
              />
              <FieldsetDescription>
                Buyers see an approximate price in their local currency in place of your set price.{" "}
                {props.buyer_currency_charging_enabled
                  ? "When this is on, buyers can also choose the currency they pay in at checkout. Your earnings and payouts are unchanged."
                  : "Checkout still uses USD."}
              </FieldsetDescription>
            </Fieldset>
            {props.buyer_currency_charging_enabled && !form.data.disable_buyer_local_currency ? (
              <Fieldset>
                <Switch
                  checked={!form.data.disable_buyer_currency_rounding}
                  onChange={(e) => form.setData("disable_buyer_currency_rounding", !e.target.checked)}
                  aria-label="Keep price endings in local currency"
                  disabled={props.is_form_disabled}
                  label="Keep price endings in local currency"
                />
                <FieldsetDescription>
                  Buyers charged in their own currency see the ending of the USD total rather than the exact converted
                  amount: a $9.99 total shows €8.99 instead of €8.53, and a $10 total shows €9. When tax is added, the
                  ending mirrored is the taxed total's, so a buyer paying in their own currency sees the same ending a
                  buyer paying in USD would. Your earnings, taxes and payouts are unchanged — the difference is absorbed
                  on our side.
                </FieldsetDescription>
              </Fieldset>
            ) : null}
          </FormSection>
        ) : null}

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
                      <Bank className="size-5" />
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
                        <CreditCard className="size-5" />
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
                    <Paypal pack="brands" className="size-5" />
                    <div>
                      <h4 className="font-bold">PayPal</h4>
                    </div>
                  </Button>
                </Tab>
              ) : null}
              {props.user.country_code === "BR" || props.stripe_connect.has_connected_stripe ? (
                <Tab key="stripe" isSelected={selectedPayoutMethod === "stripe"} asChild>
                  <Button
                    role="radio"
                    aria-checked={selectedPayoutMethod === "stripe"}
                    onClick={() => updatePayoutMethod("stripe")}
                    disabled={props.is_form_disabled}
                    className="items-start justify-start text-left"
                  >
                    <Stripe pack="brands" className="size-5" />
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
                canSetupBankPayouts={props.bank_account_details.show_bank_account}
                showPayPalPayoutsFeeNote={props.user.is_charged_paypal_payout_fee}
                isFormDisabled={props.is_form_disabled}
                paypalEmailAddress={form.data.payment_address}
                setPaypalEmailAddress={(value) => form.setData("payment_address", value)}
                hasConnectedStripe={props.stripe_connect.has_connected_stripe}
                feeInfoText={props.fee_info.paypal_fee_info_text}
                updatePayoutMethod={updatePayoutMethod}
                errorFieldNames={errorFieldNames}
                user={props.user}
                countryName={props.payout_country_name}
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
                saveCounter={saveCounter}
              />
            ) : (
              <StripeConnectSection
                stripeConnect={props.stripe_connect}
                isFormDisabled={props.is_form_disabled}
                connectAccountFeeInfoText={props.fee_info.connect_account_fee_info_text}
              />
            )}
          </section>
          {/* Not tied to the selected payout tab: the guardian requirement is a property of the
              seller, not of the rail they picked, and the presenter already decides who is asked.
              Gating it on a tab hid the form from exactly the sellers the payout gate blocks. */}
          <LegalGuardianSection
            legalGuardian={props.legal_guardian}
            sellerCountry={props.user.country_code}
            states={guardianStates}
            isFormDisabled={props.is_form_disabled}
            onSaved={refreshLegalGuardian}
          />
          {selectedPayoutMethod !== "stripe" && props.can_manage_beneficial_owners ? (
            <BeneficialOwnersSection
              countries={props.countries}
              states={props.states}
              defaultCountry={form.data.user.business_country ?? form.data.user.country}
              minDobYear={props.min_dob_year}
              isFormDisabled={props.is_form_disabled}
            />
          ) : null}
        </FormSection>
        <FormSection
          header={
            <>
              <h2>PayPal</h2>
              <a href="/help/article/275-paypal-connect" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </>
          }
        >
          <p>
            Looking for PayPal Connect? It moved to <a href={Routes.checkout_form_path()}>Checkout settings</a> — it
            lets buyers pay with PayPal at checkout and is separate from how you receive payouts.
          </p>
        </FormSection>
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
