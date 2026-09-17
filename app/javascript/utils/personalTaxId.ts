import type { ComplianceInfo, User } from "$app/types/payments";

export type TaxIdConfig = {
  label: string;
  placeholder: string;
  minLength?: number;
  maxLength?: number;
  idSuffix: string;
};

export const PERSONAL_ID_NUMBER_CONFIG: TaxIdConfig = {
  label: "Personal tax ID",
  placeholder: "123456789",
  idSuffix: "personal-id-number",
};

export const personalTaxIdError = (complianceInfo: ComplianceInfo, user: User, value: string): string | null => {
  const accountCountry = complianceInfo.is_business ? complianceInfo.business_country : complianceInfo.country;
  if (accountCountry !== "US" || !value) return null;
  const lastFourAllowed =
    complianceInfo.country === "US" && !user.need_full_ssn && !user.has_outstanding_full_ssn_requirement;
  // Match the server's formatting normalization, without treating letters as digits.
  const digits = value.replace(/[\s-]/gu, "");
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
