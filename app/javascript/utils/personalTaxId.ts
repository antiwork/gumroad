import type { ComplianceInfo, User } from "$app/types/payments";
import { COLOMBIA_ID_MAX_INPUT_LENGTH, COLOMBIA_ID_MIN_DIGITS } from "$app/utils/colombiaIdNumbers";
import {
  isValidPakistanCnic,
  PAKISTAN_CNIC_DIGITS,
  PAKISTAN_CNIC_ERROR_MESSAGE,
  PAKISTAN_CNIC_HELP_TEXT,
} from "$app/utils/pakistanCnic";
import {
  isValidUaeEmiratesId,
  UAE_EMIRATES_ID_DIGITS,
  UAE_EMIRATES_ID_ERROR_MESSAGE,
  UAE_EMIRATES_ID_HELP_TEXT,
} from "$app/utils/uaeEmiratesId";

export type TaxIdConfig = {
  label: string;
  placeholder: string;
  minLength?: number;
  maxLength?: number;
  helpText?: string;
  idSuffix: string;
};

export const PERSONAL_ID_NUMBER_CONFIG: TaxIdConfig = {
  label: "Personal tax ID",
  placeholder: "123456789",
  idSuffix: "personal-id-number",
};

export const HONG_KONG_PASSPORT_ID_CONFIG: TaxIdConfig = {
  label: "Passport number",
  placeholder: "123456789",
  idSuffix: "passport-number",
};

// A Hong Kong company's representative who lives abroad has no HKID. Stripe takes their passport
// number as `id_number` and the issuing country (stored as nationality) alongside it.
export const usesHongKongPassport = (complianceInfo: ComplianceInfo): boolean =>
  complianceInfo.is_business &&
  complianceInfo.business_country === "HK" &&
  !!complianceInfo.country &&
  complianceInfo.country !== "HK";

export const usesUsTaxId = (complianceInfo: ComplianceInfo, user: User): boolean => {
  const accountCountry = complianceInfo.is_business ? complianceInfo.business_country : complianceInfo.country;
  return (
    accountCountry === "US" &&
    (complianceInfo.country === "US" || getIndividualTaxIdConfig(complianceInfo, user) === PERSONAL_ID_NUMBER_CONFIG)
  );
};

export const normalizeUsTaxId = (value: string): string => value.replace(/[\s-]/gu, "");

// Mirrors UpdateUserComplianceInfo#individual_id_country_matches? for Pakistan: the number belongs
// to the representative, so the country guard only governs an account whose legal entity is in
// Pakistan too. A foreign representative of a Pakistani business enters their own country's
// document instead, and must not be held to a CNIC.
export const usesPakistanCnic = (complianceInfo: ComplianceInfo): boolean => {
  const accountCountry = complianceInfo.is_business ? complianceInfo.business_country : complianceInfo.country;
  return accountCountry === "PK" && complianceInfo.country === "PK";
};

// Same representative/account rule as usesPakistanCnic, mirroring the server's AE guard.
export const usesUaeEmiratesId = (complianceInfo: ComplianceInfo): boolean => {
  const accountCountry = complianceInfo.is_business ? complianceInfo.business_country : complianceInfo.country;
  return accountCountry === "AE" && complianceInfo.country === "AE";
};

export const personalTaxIdError = (complianceInfo: ComplianceInfo, user: User, value: string): string | null => {
  if (!value) return null;
  if (usesPakistanCnic(complianceInfo)) return isValidPakistanCnic(value) ? null : PAKISTAN_CNIC_ERROR_MESSAGE;
  if (usesUaeEmiratesId(complianceInfo)) return isValidUaeEmiratesId(value) ? null : UAE_EMIRATES_ID_ERROR_MESSAGE;
  if (!usesUsTaxId(complianceInfo, user)) return null;
  const lastFourAllowed =
    complianceInfo.country === "US" && !user.need_full_ssn && !user.has_outstanding_full_ssn_requirement;
  const digits = normalizeUsTaxId(value);
  if (lastFourAllowed ? /^\d{4}$/u.test(digits) : /^\d{9}$/u.test(digits)) return null;
  return lastFourAllowed ? "Enter the last 4 digits of your SSN." : "Enter a 9-digit US ITIN or SSN.";
};

export const stripeRequirementLabel = (key: string): string => {
  if (key === "id_number") return "Personal tax ID";
  if (key === "verification.document") return "Identity document";
  if (key === "ssn_last_4") return "Last 4 of SSN";
  if (key.startsWith("dob.")) return "Date of birth";
  if (key.startsWith("address.")) return "Address";
  const words = key.replace(/[._]+/gu, " ").trim();
  return words.charAt(0).toUpperCase() + words.slice(1);
};

export const getIndividualTaxIdConfig = (complianceInfo: ComplianceInfo, user: User): TaxIdConfig => {
  if (usesHongKongPassport(complianceInfo)) return HONG_KONG_PASSPORT_ID_CONFIG;

  if (complianceInfo.country === "US") {
    return user.need_full_ssn
      ? {
          label: "Social Security Number",
          placeholder: "•••-••-••••",
          minLength: 9,
          maxLength: 11,
          idSuffix: "social-security-number-full",
        }
      : {
          label: "Last 4 digits of SSN",
          placeholder: "••••",
          minLength: 4,
          maxLength: 4,
          idSuffix: "social-security-number",
        };
  }

  const configs: Record<string, TaxIdConfig> = {
    CA: {
      label: "Social Insurance Number",
      placeholder: "•••••••••",
      minLength: 9,
      maxLength: 9,
      idSuffix: "social-insurance-number",
    },
    CO: {
      // Colombia issues two personal IDs: the Cédula de Ciudadanía to citizens and the Cédula de
      // Extranjería to foreign residents. Both are sent to Stripe as the generic
      // individual.id_number, so both are accepted — the label has to say so, otherwise a foreign
      // resident reads "Cédula de Ciudadanía" and concludes their ID cannot be used.
      label: "Cédula de Ciudadanía (CC) or Cédula de Extranjería (CE)",
      placeholder: "1234567890",
      minLength: COLOMBIA_ID_MIN_DIGITS,
      maxLength: COLOMBIA_ID_MAX_INPUT_LENGTH,
      idSuffix: "colombia-id-number",
    },
    UY: {
      label: "Cédula de Identidad (CI)",
      placeholder: "1.123.123-1",
      minLength: 11,
      maxLength: 11,
      idSuffix: "uruguay-id-number",
    },
    HK: {
      label: "Hong Kong ID Number",
      placeholder: "123456789",
      minLength: 8,
      maxLength: 9,
      idSuffix: "hong-kong-id-number",
    },
    SG: {
      label: "NRIC number / FIN",
      placeholder: "S1234567A",
      minLength: 9,
      // No maxLength on purpose: the validation tolerates spaces/dashes inside a
      // pasted NRIC ("S 1234567 - A"), so a browser length cap would silently
      // truncate those pastes. The inline regex and the server-side check in
      // UpdateUserComplianceInfo enforce the actual format.
      idSuffix: "singapore-id-number",
    },
    AE: {
      label: "Emirates ID",
      placeholder: "784-1234-1234567-1",
      minLength: UAE_EMIRATES_ID_DIGITS,
      // No maxLength: the ID is printed with three dashes, so a 15-character cap cuts it to 13 digits.
      // isValidUaeEmiratesId and the server check the actual shape.
      helpText: UAE_EMIRATES_ID_HELP_TEXT,
      idSuffix: "uae-id-number",
    },
    MX: {
      label: "Personal RFC",
      placeholder: "1234567891234",
      minLength: 13,
      maxLength: 13,
      idSuffix: "mexico-id-number",
    },
    KZ: {
      label: "Individual identification number (IIN)",
      placeholder: "123456789",
      minLength: 9,
      maxLength: 12,
      idSuffix: "kazakhstan-id-number",
    },
    AR: {
      label: "CUIL",
      placeholder: "12-12345678-1",
      minLength: 13,
      maxLength: 13,
      idSuffix: "argentina-id-number",
    },
    PE: { label: "DNI number", placeholder: "12345678-9", minLength: 10, maxLength: 10, idSuffix: "peru-id-number" },
    PK: {
      label: "National Identity Card Number (SNIC or CNIC)",
      placeholder: "12345-1234567-1",
      minLength: PAKISTAN_CNIC_DIGITS,
      // No maxLength: a cap cuts a CNIC pasted with its dashes and a stray space. isValidPakistanCnic
      // and the server check the actual shape.
      helpText: PAKISTAN_CNIC_HELP_TEXT,
      idSuffix: "snic",
    },
    CR: {
      label: "Tax Identification Number",
      placeholder: "1234567890",
      minLength: 9,
      maxLength: 12,
      idSuffix: "costa-rica-id-number",
    },
    CL: {
      label: "Rol Único Tributario (RUT)",
      placeholder: "123456789",
      minLength: 8,
      maxLength: 9,
      idSuffix: "chile-id-number",
    },
    DO: {
      label: "Cédula de identidad y electoral (CIE)",
      placeholder: "123-1234567-1",
      minLength: 13,
      maxLength: 13,
      idSuffix: "dominican-republic-id-number",
    },
    BO: {
      label: "Cédula de Identidad (CI)",
      placeholder: "12345678",
      minLength: 8,
      maxLength: 8,
      idSuffix: "bolivia-id-number",
    },
    PY: {
      label: "Cédula de Identidad (CI)",
      placeholder: "1234567",
      minLength: 7,
      maxLength: 7,
      idSuffix: "paraguay-id-number",
    },
    BD: {
      label: "Personal ID number",
      placeholder: "123456789",
      minLength: 1,
      maxLength: 20,
      idSuffix: "bangladesh-id-number",
    },
    MZ: {
      label: "Mozambique Taxpayer Single ID Number (NUIT)",
      placeholder: "123456789",
      minLength: 9,
      maxLength: 9,
      idSuffix: "mozambique-id-number",
    },
    GT: {
      // Stripe lowered the individual.id_number floor to 7 characters, so a short SAT NIT such as
      // "805813-K" (6 digits plus the check letter) is valid. The input floor has to match
      // isValidGuatemalaNit, otherwise the browser rejects a value the check accepts.
      label: "Número de Identificación Tributaria (NIT)",
      placeholder: "805813-K",
      minLength: 7,
      maxLength: 12,
      idSuffix: "guatemala-id-number",
    },
    BR: {
      label: "Cadastro de Pessoas Físicas (CPF)",
      placeholder: "123.456.789-00",
      minLength: 11,
      maxLength: 14,
      idSuffix: "brazil-id-number",
    },
  };

  return (complianceInfo.country ? configs[complianceInfo.country] : null) ?? PERSONAL_ID_NUMBER_CONFIG;
};
