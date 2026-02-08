import cx from "classnames";
import parsePhoneNumberFromString, { CountryCode } from "libphonenumber-js";
import * as React from "react";
import { cast } from "ts-safe-cast";

import type { ComplianceInfo, FormFieldName, User } from "$app/types/payments";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";

type StateConfig = {
  states: { code: string; name: string }[];
  label: string;
  idSuffix: string;
};

type PrefectureConfig = {
  states: { value: string; label: string; kana: string }[];
  label: string;
  idSuffix: string;
};

type TaxIdConfig = {
  label: string;
  placeholder: string;
  minLength?: number;
  maxLength?: number;
  idSuffix: string;
};

const AccountDetailsSection = ({
  user,
  complianceInfo,
  updateComplianceInfo,
  isFormDisabled,
  minDobYear,
  countries,
  uaeBusinessTypes,
  indiaBusinessTypes,
  canadaBusinessTypes,
  states,
  errorFieldNames,
}: {
  user: User;
  complianceInfo: ComplianceInfo;
  updateComplianceInfo: (newComplianceInfo: Partial<ComplianceInfo>) => void;
  isFormDisabled: boolean;
  minDobYear: number;
  countries: Record<string, string>;
  uaeBusinessTypes: { code: string; name: string }[];
  indiaBusinessTypes: { code: string; name: string }[];
  canadaBusinessTypes: { code: string; name: string }[];
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
  errorFieldNames: Set<FormFieldName>;
}) => {
  const uid = React.useId();

  const formatPhoneNumber = (phoneNumber: string, country_code: string | null): string => {
    const countryCode: CountryCode = cast(country_code);
    return parsePhoneNumberFromString(phoneNumber, countryCode)?.format("E.164") ?? phoneNumber;
  };

  const getBusinessTypes = (): { code: string; name: string }[] | null => {
    const businessTypesMap: Record<string, { code: string; name: string }[]> = {
      AE: uaeBusinessTypes,
      IN: indiaBusinessTypes,
      CA: canadaBusinessTypes,
    };
    return complianceInfo.business_country ? (businessTypesMap[complianceInfo.business_country] ?? null) : null;
  };

  const getBusinessStateConfig = (): StateConfig | PrefectureConfig | null => {
    switch (complianceInfo.business_country) {
      case "US":
        return { states: states.us, label: "State", idSuffix: "business-state" };
      case "CA":
        return { states: states.ca, label: "Province", idSuffix: "business-province" };
      case "AU":
        return { states: states.au, label: "State", idSuffix: "business-state" };
      case "MX":
        return { states: states.mx, label: "State", idSuffix: "business-state" };
      case "AE":
        return { states: states.ae, label: "Province", idSuffix: "business-state" };
      case "IE":
        return { states: states.ir, label: "County", idSuffix: "business-county" };
      case "JP":
        return { states: states.jp, label: "Prefecture", idSuffix: "business-prefecture" };
      case "BR":
        return { states: states.br, label: "State", idSuffix: "business-state" };
      default:
        return null;
    }
  };

  const getIndividualStateConfig = (): StateConfig | PrefectureConfig | null => {
    switch (complianceInfo.country) {
      case "US":
        return { states: states.us, label: "State", idSuffix: "creator-state" };
      case "CA":
        return { states: states.ca, label: "Province", idSuffix: "creator-province" };
      case "AU":
        return { states: states.au, label: "State", idSuffix: "creator-state" };
      case "MX":
        return { states: states.mx, label: "State", idSuffix: "creator-state" };
      case "AE":
        return { states: states.ae, label: "Province", idSuffix: "creator-province" };
      case "IE":
        return { states: states.ir, label: "County", idSuffix: "creator-county" };
      case "BR":
        return { states: states.br, label: "State", idSuffix: "creator-state" };
      default:
        return null;
    }
  };

  const getBusinessTaxIdConfig = (): TaxIdConfig => {
    const configs: Record<string, { label: string; placeholder: string }> = {
      US: { label: "Business Tax ID (EIN, or SSN for sole proprietors)", placeholder: "12-3456789" },
      CA: { label: "Business Number (BN)", placeholder: "123456789" },
      AU: { label: "Australian Business Number (ABN)", placeholder: "12 123 456 789" },
      GB: { label: "Company Number (CRN)", placeholder: "12345678" },
      MX: { label: "Business RFC", placeholder: "12345678" },
    };

    const config = complianceInfo.business_country ? configs[complianceInfo.business_country] : null;
    return {
      label: config?.label ?? "Company tax ID",
      placeholder: config?.placeholder ?? "12345678",
      idSuffix: "business-tax-id",
    };
  };

  const getIndividualTaxIdConfig = (): TaxIdConfig | null => {
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
        label: "Cédula de Ciudadanía (CC)",
        placeholder: "1.123.123.123",
        minLength: 13,
        maxLength: 13,
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
        placeholder: "123456789",
        minLength: 9,
        maxLength: 9,
        idSuffix: "singapore-id-number",
      },
      AE: {
        label: "Emirates ID",
        placeholder: "123456789123456",
        minLength: 15,
        maxLength: 15,
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
        placeholder: "•••••••••",
        minLength: 13,
        maxLength: 13,
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
        label: "Número de Identificación Tributaria (NIT)",
        placeholder: "1234567-8",
        minLength: 8,
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

    return complianceInfo.country ? (configs[complianceInfo.country] ?? null) : null;
  };

  const isPrefectureConfig = (config: StateConfig | PrefectureConfig): config is PrefectureConfig =>
    "value" in (config.states[0] || {});

  const renderStateSelect = (
    config: StateConfig | PrefectureConfig,
    value: string | null,
    onChange: (value: string) => void,
    fieldName: FormFieldName,
  ): React.ReactNode => {
    if (isPrefectureConfig(config)) {
      return (
        <fieldset className={cx({ danger: errorFieldNames.has(fieldName) })}>
          <legend>
            <label htmlFor={`${uid}-${config.idSuffix}`}>{config.label}</label>
          </legend>
          <select
            id={`${uid}-${config.idSuffix}`}
            required={complianceInfo.is_business}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has(fieldName)}
            value={value || ""}
            onChange={(evt) => onChange(evt.target.value)}
          >
            <option value="" disabled>
              {config.label}
            </option>
            {config.states.map((prefecture) => (
              <option key={prefecture.value} value={prefecture.value}>
                {prefecture.label}
              </option>
            ))}
          </select>
        </fieldset>
      );
    }

    return (
      <fieldset className={cx({ danger: errorFieldNames.has(fieldName) })}>
        <legend>
          <label htmlFor={`${uid}-${config.idSuffix}`}>{config.label}</label>
        </legend>
        <select
          id={`${uid}-${config.idSuffix}`}
          required={complianceInfo.is_business}
          disabled={isFormDisabled}
          aria-invalid={errorFieldNames.has(fieldName)}
          value={value || ""}
          onChange={(evt) => onChange(evt.target.value)}
        >
          <option value="" disabled>
            {config.label}
          </option>
          {config.states.map((state) => (
            <option key={state.code} value={state.code}>
              {state.name}
            </option>
          ))}
        </select>
      </fieldset>
    );
  };

  const businessTypes = getBusinessTypes();
  const businessStateConfig = getBusinessStateConfig();
  const individualStateConfig = getIndividualStateConfig();
  const businessTaxIdConfig = getBusinessTaxIdConfig();
  const individualTaxIdConfig = getIndividualTaxIdConfig();

  const showAccountTypeSection = complianceInfo.is_business
    ? complianceInfo.business_country !== "AE"
    : complianceInfo.country !== "AE";

  const showNationalityField =
    user.country_code === "AE" ||
    user.country_code === "SG" ||
    user.country_code === "PK" ||
    user.country_code === "BD";

  const needsIndividualTaxId =
    (complianceInfo.is_business &&
      complianceInfo.business_country !== null &&
      user.individual_tax_id_needed_countries.includes(complianceInfo.business_country)) ||
    (complianceInfo.country !== null && user.individual_tax_id_needed_countries.includes(complianceInfo.country));

  return (
    <section className="grid gap-8">
      {showAccountTypeSection ? (
        <section>
          <fieldset>
            <legend>
              <label>Account type</label>
              <a href="/help/article/260-your-payout-settings-page">What type of account should I choose?</a>
            </legend>
          </fieldset>
          <div className="radio-buttons" role="radiogroup">
            <Button
              role="radio"
              key="individual"
              aria-checked={!complianceInfo.is_business}
              onClick={() => updateComplianceInfo({ is_business: false })}
              disabled={isFormDisabled}
            >
              <Icon name="person" />
              <div>
                <h4>Individual</h4>
                When you are selling as yourself
              </div>
            </Button>
            <Button
              role="radio"
              key="business"
              aria-checked={complianceInfo.is_business}
              onClick={() =>
                updateComplianceInfo({
                  is_business: true,
                  business_country: complianceInfo.business_country ?? complianceInfo.country,
                })
              }
              disabled={isFormDisabled}
            >
              <Icon name="shop-window" />
              <div>
                <h4>Business</h4>
                When you are selling as a business
              </div>
            </Button>
          </div>
        </section>
      ) : null}
      {complianceInfo.is_business ? (
        <section className="grid gap-8">
          <div
            style={{
              display: "grid",
              gap: "var(--spacer-5)",
              gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
            }}
          >
            <fieldset className={cx({ danger: errorFieldNames.has("business_name") })}>
              <legend>
                <label htmlFor={`${uid}-business-legal-name`}>Legal business name</label>
              </legend>
              <input
                id={`${uid}-business-legal-name`}
                placeholder="Acme"
                required={complianceInfo.is_business}
                value={complianceInfo.business_name || ""}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("business_name")}
                onChange={(evt) => updateComplianceInfo({ business_name: evt.target.value })}
              />
            </fieldset>
            <fieldset className={cx({ danger: errorFieldNames.has("business_type") })}>
              <legend>
                <label htmlFor={`${uid}-business-type`}>Type</label>
              </legend>
              {businessTypes ? (
                <select
                  id={`${uid}-business-type`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_type")}
                  value={complianceInfo.business_type || "Type"}
                  onChange={(evt) => updateComplianceInfo({ business_type: evt.target.value })}
                >
                  <option disabled>Type</option>
                  {businessTypes.map((businessType) => (
                    <option key={businessType.code} value={businessType.code}>
                      {businessType.name}
                    </option>
                  ))}
                </select>
              ) : (
                <select
                  id={`${uid}-business-type`}
                  disabled={isFormDisabled}
                  value={complianceInfo.business_type || "Type"}
                  required
                  aria-invalid={errorFieldNames.has("business_type")}
                  onChange={(evt) => updateComplianceInfo({ business_type: evt.target.value })}
                >
                  <option disabled>Type</option>
                  <option value="llc">LLC</option>
                  <option value="partnership">Partnership</option>
                  <option value="profit">Non Profit</option>
                  <option value="sole_proprietorship">Sole Proprietorship</option>
                  <option value="corporation">Corporation</option>
                </select>
              )}
            </fieldset>
          </div>
          {complianceInfo.business_country === "JP" ? (
            <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
              <fieldset className={cx({ danger: errorFieldNames.has("business_name_kanji") })}>
                <legend>
                  <label htmlFor={`${uid}-business-name-kanji`}>Business Name (Kanji)</label>
                </legend>
                <input
                  id={`${uid}-business-name-kanji`}
                  type="text"
                  placeholder="Legal Business Name (Kanji)"
                  value={complianceInfo.business_name_kanji || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_name_kanji")}
                  required
                  onChange={(evt) => updateComplianceInfo({ business_name_kanji: evt.target.value })}
                />
              </fieldset>
              <fieldset className={cx({ danger: errorFieldNames.has("business_name_kana") })}>
                <legend>
                  <label htmlFor={`${uid}-business-name-kana`}>Legal Business Name (Kana)</label>
                </legend>
                <input
                  id={`${uid}-business-name-kana`}
                  type="text"
                  placeholder="Business Name (Kana)"
                  value={complianceInfo.business_name_kana || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_name_kana")}
                  required
                  onChange={(evt) => updateComplianceInfo({ business_name_kana: evt.target.value })}
                />
              </fieldset>
            </div>
          ) : null}
          {complianceInfo.business_country === "JP" ? (
            <>
              <div
                style={{
                  display: "grid",
                  gap: "var(--spacer-5)",
                  gridAutoFlow: "column",
                  gridAutoColumns: "1fr",
                  alignItems: "end",
                }}
              >
                <fieldset className={cx({ danger: errorFieldNames.has("business_building_number") })}>
                  <legend>
                    <label htmlFor={`${uid}-business-building-number`}>Block / Building number</label>
                  </legend>
                  <input
                    id={`${uid}-business-building-number`}
                    type="text"
                    placeholder="1-1"
                    value={complianceInfo.business_building_number || ""}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_building_number")}
                    required
                    onChange={(evt) => updateComplianceInfo({ business_building_number: evt.target.value })}
                  />
                </fieldset>
                <fieldset className={cx({ danger: errorFieldNames.has("business_building_number_kana") })}>
                  <legend>
                    <label htmlFor={`${uid}-business-building-number-kana`}>Block / Building number (Kana)</label>
                  </legend>
                  <input
                    id={`${uid}-business-building-number-kana`}
                    type="text"
                    placeholder="イチノイチ"
                    value={complianceInfo.business_building_number_kana || ""}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_building_number_kana")}
                    required
                    onChange={(evt) => updateComplianceInfo({ business_building_number_kana: evt.target.value })}
                  />
                </fieldset>
              </div>
              <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
                <fieldset className={cx({ danger: errorFieldNames.has("business_street_address_kanji") })}>
                  <legend>
                    <label htmlFor={`${uid}-business-street-address-kanji`}>Business town/Cho-me (Kanji)</label>
                  </legend>
                  <input
                    id={`${uid}-business-street-address-kanji`}
                    type="text"
                    placeholder="千代田"
                    value={complianceInfo.business_street_address_kanji || ""}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_street_address_kanji")}
                    required
                    onChange={(evt) => updateComplianceInfo({ business_street_address_kanji: evt.target.value })}
                  />
                </fieldset>
                <fieldset className={cx({ danger: errorFieldNames.has("business_street_address_kana") })}>
                  <legend>
                    <label htmlFor={`${uid}-business-street-address-kana`}>Business town/Cho-me (Kana)</label>
                  </legend>
                  <input
                    id={`${uid}-business-street-address-kana`}
                    type="text"
                    placeholder="チヨダ"
                    value={complianceInfo.business_street_address_kana || ""}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_street_address_kana")}
                    required
                    onChange={(evt) => updateComplianceInfo({ business_street_address_kana: evt.target.value })}
                  />
                </fieldset>
              </div>
            </>
          ) : (
            <fieldset className={cx({ danger: errorFieldNames.has("business_street_address") })}>
              <legend>
                <label htmlFor={`${uid}-business-street-address`}>Address</label>
              </legend>
              <input
                id={`${uid}-business-street-address`}
                placeholder="123 smith street"
                value={complianceInfo.business_street_address || ""}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("business_street_address")}
                onChange={(evt) => updateComplianceInfo({ business_street_address: evt.target.value })}
              />
            </fieldset>
          )}
          <div
            style={{
              display: "grid",
              gap: "var(--spacer-5)",
              gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
            }}
          >
            <fieldset className={cx({ danger: errorFieldNames.has("business_city") })}>
              <legend>
                <label htmlFor={`${uid}-business-city`}>City</label>
              </legend>
              <input
                id={`${uid}-business-city`}
                placeholder="Springfield"
                value={complianceInfo.business_city || ""}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("business_city")}
                onChange={(evt) => updateComplianceInfo({ business_city: evt.target.value })}
              />
            </fieldset>
            {businessStateConfig
              ? renderStateSelect(
                  businessStateConfig,
                  complianceInfo.business_state,
                  (value) => updateComplianceInfo({ business_state: value }),
                  "business_state",
                )
              : null}
            <fieldset className={cx({ danger: errorFieldNames.has("business_zip_code") })}>
              <legend>
                <label htmlFor={`${uid}-business-zip-code`}>
                  {complianceInfo.business_country === "US" ? "ZIP code" : "Postal code"}
                </label>
              </legend>
              <input
                id={`${uid}-business-zip-code`}
                placeholder="12345"
                required={complianceInfo.is_business}
                value={complianceInfo.business_zip_code || ""}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("business_zip_code")}
                onChange={(evt) => updateComplianceInfo({ business_zip_code: evt.target.value })}
              />
            </fieldset>
          </div>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-business-country`}>Country</label>
            </legend>
            <select
              id={`${uid}-business-country`}
              value={complianceInfo.business_country || ""}
              disabled={isFormDisabled}
              required={complianceInfo.is_business}
              onChange={(evt) => updateComplianceInfo({ updated_country_code: evt.target.value })}
            >
              {Object.entries(countries).map(([code, name]) => (
                <option key={code} value={code} disabled={name.includes("(not supported)")}>
                  {name}
                </option>
              ))}
            </select>
          </fieldset>
          <fieldset className={cx({ danger: errorFieldNames.has("business_phone") })}>
            <legend>
              <label htmlFor={`${uid}-business-phone-number`}>Business phone number</label>
            </legend>
            <input
              id={`${uid}-business-phone-number`}
              type="tel"
              placeholder="555-555-5555"
              required={complianceInfo.is_business}
              value={complianceInfo.business_phone || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("business_phone")}
              onChange={(evt) =>
                updateComplianceInfo({
                  business_phone: formatPhoneNumber(evt.target.value, complianceInfo.business_country),
                })
              }
            />
          </fieldset>
          {user.country_supports_native_payouts || complianceInfo.business_country === "AE" ? (
            <fieldset className={cx({ danger: errorFieldNames.has("business_tax_id") })}>
              <legend>
                <label htmlFor={`${uid}-${businessTaxIdConfig.idSuffix}`}>{businessTaxIdConfig.label}</label>
                {complianceInfo.business_country === "US" ? (
                  <div className="small">
                    <a href="/help/article/260-your-payout-settings-page">I'm not sure what my Tax ID is.</a>
                  </div>
                ) : null}
              </legend>
              <input
                id={`${uid}-${businessTaxIdConfig.idSuffix}`}
                type="text"
                placeholder={user.business_tax_id_entered ? "Hidden for security" : businessTaxIdConfig.placeholder}
                required={complianceInfo.is_business}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("business_tax_id")}
                onChange={(evt) => updateComplianceInfo({ business_tax_id: evt.target.value })}
              />
            </fieldset>
          ) : null}
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-personal-address-is-business-address`}>
                <input
                  id={`${uid}-personal-address-is-business-address`}
                  type="checkbox"
                  disabled={isFormDisabled}
                  onChange={(e) =>
                    e.target.checked &&
                    updateComplianceInfo({
                      street_address: complianceInfo.business_street_address,
                      city: complianceInfo.business_city,
                      state: complianceInfo.business_state,
                      zip_code: complianceInfo.business_zip_code,
                    })
                  }
                />
                Same as business
              </label>
            </legend>
          </fieldset>
        </section>
      ) : null}
      <section className="grid gap-8">
        <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
          <fieldset className={cx({ danger: errorFieldNames.has("first_name") })}>
            <legend>
              <label htmlFor={`${uid}-creator-first-name`}>First name</label>
            </legend>
            <input
              id={`${uid}-creator-first-name`}
              type="text"
              placeholder="First name"
              value={complianceInfo.first_name || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("first_name")}
              required
              onChange={(evt) => updateComplianceInfo({ first_name: evt.target.value })}
            />
            <small>Include your middle name if it appears on your ID.</small>
          </fieldset>
          <fieldset className={cx({ danger: errorFieldNames.has("last_name") })}>
            <legend>
              <label htmlFor={`${uid}-creator-last-name`}>Last name</label>
            </legend>
            <input
              id={`${uid}-creator-last-name`}
              type="text"
              placeholder="Last name"
              value={complianceInfo.last_name || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("last_name")}
              required
              onChange={(evt) => updateComplianceInfo({ last_name: evt.target.value })}
            />
          </fieldset>
        </div>
        {complianceInfo.is_business && complianceInfo.country === "CA" ? (
          <fieldset className={cx({ danger: errorFieldNames.has("job_title") })}>
            <legend>
              <label htmlFor={`${uid}-creator-job-title`}>Job title</label>
            </legend>
            <input
              id={`${uid}-creator-job-title`}
              type="text"
              placeholder="CEO"
              value={complianceInfo.job_title || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("job_title")}
              required
              onChange={(evt) => updateComplianceInfo({ job_title: evt.target.value })}
            />
          </fieldset>
        ) : null}
        {complianceInfo.country === "JP" ? (
          <>
            <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
              <fieldset className={cx({ danger: errorFieldNames.has("first_name_kanji") })}>
                <legend>
                  <label htmlFor={`${uid}-creator-first-name-kanji`}>First name (Kanji)</label>
                </legend>
                <input
                  id={`${uid}-creator-first-name-kanji`}
                  type="text"
                  placeholder="First name (Kanji)"
                  value={complianceInfo.first_name_kanji || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("first_name_kanji")}
                  required
                  onChange={(evt) => updateComplianceInfo({ first_name_kanji: evt.target.value })}
                />
              </fieldset>
              <fieldset className={cx({ danger: errorFieldNames.has("last_name_kanji") })}>
                <legend>
                  <label htmlFor={`${uid}-creator-last-name-kanji`}>Last name (Kanji)</label>
                </legend>
                <input
                  id={`${uid}-creator-last-name-kanji`}
                  type="text"
                  placeholder="Last name (Kanji)"
                  value={complianceInfo.last_name_kanji || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("last_name_kanji")}
                  required
                  onChange={(evt) => updateComplianceInfo({ last_name_kanji: evt.target.value })}
                />
              </fieldset>
            </div>
            <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
              <fieldset className={cx({ danger: errorFieldNames.has("first_name_kana") })}>
                <legend>
                  <label htmlFor={`${uid}-creator-first-name-kana`}>First name (Kana)</label>
                </legend>
                <input
                  id={`${uid}-creator-first-name-kana`}
                  type="text"
                  placeholder="First name (Kana)"
                  value={complianceInfo.first_name_kana || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("first_name_kana")}
                  required
                  onChange={(evt) => updateComplianceInfo({ first_name_kana: evt.target.value })}
                />
              </fieldset>
              <fieldset className={cx({ danger: errorFieldNames.has("last_name_kana") })}>
                <legend>
                  <label htmlFor={`${uid}-creator-last-name-kana`}>Last name (Kana)</label>
                </legend>
                <input
                  id={`${uid}-creator-last-name-kana`}
                  type="text"
                  placeholder="Last name (Kana)"
                  value={complianceInfo.last_name_kana || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("last_name_kana")}
                  required
                  onChange={(evt) => updateComplianceInfo({ last_name_kana: evt.target.value })}
                />
              </fieldset>
            </div>
          </>
        ) : null}
        {complianceInfo.country === "JP" ? (
          <>
            <div
              style={{
                display: "grid",
                gap: "var(--spacer-5)",
                gridAutoFlow: "column",
                gridAutoColumns: "1fr",
                alignItems: "end",
              }}
            >
              <fieldset className={cx({ danger: errorFieldNames.has("building_number") })}>
                <legend>
                  <label htmlFor={`${uid}-creator-building-number`}>Block / Building number</label>
                </legend>
                <input
                  id={`${uid}-creator-building-number`}
                  type="text"
                  placeholder="1-1"
                  value={complianceInfo.building_number || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("building_number")}
                  required
                  onChange={(evt) => updateComplianceInfo({ building_number: evt.target.value })}
                />
              </fieldset>
              <fieldset className={cx({ danger: errorFieldNames.has("building_number_kana") })}>
                <legend>
                  <label htmlFor={`${uid}-creator-building-number-kana`}>Block / Building number (Kana)</label>
                </legend>
                <input
                  id={`${uid}-creator-building-number-kana`}
                  type="text"
                  placeholder="イチノイチ"
                  value={complianceInfo.building_number_kana || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("building_number_kana")}
                  required
                  onChange={(evt) => updateComplianceInfo({ building_number_kana: evt.target.value })}
                />
              </fieldset>
            </div>
            <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
              <fieldset className={cx({ danger: errorFieldNames.has("street_address_kanji") })}>
                <legend>
                  <label htmlFor={`${uid}-creator-street-address-kanji`}>Town/Cho-me (Kanji)</label>
                </legend>
                <input
                  id={`${uid}-creator-street-address-kanji`}
                  type="text"
                  placeholder="千代田"
                  value={complianceInfo.street_address_kanji || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("street_address_kanji")}
                  required
                  onChange={(evt) => updateComplianceInfo({ street_address_kanji: evt.target.value })}
                />
              </fieldset>
              <fieldset className={cx({ danger: errorFieldNames.has("street_address_kana") })}>
                <legend>
                  <label htmlFor={`${uid}-creator-street-address-kana`}>Town/Cho-me (Kana)</label>
                </legend>
                <input
                  id={`${uid}-creator-street-address-kana`}
                  type="text"
                  placeholder="チヨダ"
                  value={complianceInfo.street_address_kana || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("street_address_kana")}
                  required
                  onChange={(evt) => updateComplianceInfo({ street_address_kana: evt.target.value })}
                />
              </fieldset>
            </div>
          </>
        ) : (
          <fieldset className={cx({ danger: errorFieldNames.has("street_address") })}>
            <legend>
              <label htmlFor={`${uid}-creator-street-address`}>Address</label>
            </legend>
            <input
              id={`${uid}-creator-street-address`}
              type="text"
              placeholder="Street address"
              required
              value={complianceInfo.street_address || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("street_address")}
              onChange={(evt) => updateComplianceInfo({ street_address: evt.target.value })}
            />
          </fieldset>
        )}
      </section>
      {complianceInfo.country === "JP" ? (
        <div
          style={{
            display: "grid",
            gap: "var(--spacer-5)",
            gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
          }}
        >
          <fieldset className={cx({ danger: errorFieldNames.has("state") })}>
            <legend>
              <label htmlFor={`${uid}-creator-prefecture`}>Prefecture</label>
            </legend>
            <select
              id={`${uid}-creator-prefecture`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || ""}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option value="" disabled>
                Prefecture
              </option>
              {states.jp.map((prefecture) => (
                <option key={prefecture.value} value={prefecture.value}>
                  {prefecture.label}
                </option>
              ))}
            </select>
          </fieldset>
          <fieldset className={cx({ danger: errorFieldNames.has("zip_code") })}>
            <legend>
              <label htmlFor={`${uid}-creator-zip-code`}>Postal code</label>
            </legend>
            <input
              id={`${uid}-creator-zip-code`}
              type="text"
              placeholder="100-0000"
              value={complianceInfo.zip_code || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("zip_code")}
              required
              onChange={(evt) => updateComplianceInfo({ zip_code: evt.target.value })}
            />
          </fieldset>
        </div>
      ) : (
        <div
          style={{
            display: "grid",
            gap: "var(--spacer-5)",
            gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
          }}
        >
          <fieldset className={cx({ danger: errorFieldNames.has("city") })}>
            <legend>
              <label htmlFor={`${uid}-creator-city`}>City</label>
            </legend>
            <input
              id={`${uid}-creator-city`}
              type="text"
              placeholder="City"
              value={complianceInfo.city || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("city")}
              required
              onChange={(evt) => updateComplianceInfo({ city: evt.target.value })}
            />
          </fieldset>
          {individualStateConfig
            ? renderStateSelect(
                individualStateConfig,
                complianceInfo.state,
                (value) => updateComplianceInfo({ state: value }),
                "state",
              )
            : null}
          <fieldset className={cx({ danger: errorFieldNames.has("zip_code") })}>
            <legend>
              <label htmlFor={`${uid}-creator-zip-code`}>
                {complianceInfo.country === "US" ? "ZIP code" : "Postal code"}
              </label>
            </legend>
            <input
              id={`${uid}-creator-zip-code`}
              type="text"
              placeholder={complianceInfo.country === "US" ? "ZIP code" : "Postal code"}
              value={complianceInfo.zip_code || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("zip_code")}
              required
              onChange={(evt) => updateComplianceInfo({ zip_code: evt.target.value })}
            />
          </fieldset>
        </div>
      )}
      <fieldset>
        <legend>
          <label htmlFor={`${uid}-creator-country`}>Country</label>
        </legend>
        <select
          id={`${uid}-creator-country`}
          disabled={isFormDisabled}
          value={complianceInfo.country || ""}
          onChange={(evt) =>
            updateComplianceInfo(
              complianceInfo.is_business ? { country: evt.target.value } : { updated_country_code: evt.target.value },
            )
          }
        >
          {Object.entries(countries).map(([code, name]) => (
            <option key={code} value={code} disabled={name.includes("(not supported)")}>
              {name}
            </option>
          ))}
        </select>
      </fieldset>
      <fieldset className={cx({ danger: errorFieldNames.has("phone") })}>
        <legend>
          <label htmlFor={`${uid}-creator-phone`}>Phone number</label>
        </legend>
        <input
          id={`${uid}-creator-phone`}
          type="tel"
          placeholder="Phone number"
          value={complianceInfo.phone || ""}
          disabled={isFormDisabled}
          aria-invalid={errorFieldNames.has("phone")}
          required
          onChange={(evt) =>
            updateComplianceInfo({ phone: formatPhoneNumber(evt.target.value, complianceInfo.country) })
          }
        />
      </fieldset>
      <fieldset>
        <legend>
          <label>Date of Birth</label>
          <a href="/help/article/260-your-payout-settings-page">Why does Gumroad need this information?</a>
        </legend>
        <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
          <fieldset className={cx({ danger: errorFieldNames.has("dob_month") })}>
            <select
              id={`${uid}-creator-dob-month`}
              disabled={isFormDisabled}
              required
              aria-label="Month"
              aria-invalid={errorFieldNames.has("dob_month")}
              value={complianceInfo.dob_month || "Month"}
              onChange={(evt) => updateComplianceInfo({ dob_month: Number(evt.target.value) })}
            >
              <option disabled>Month</option>
              {Array.from({ length: 12 }, (_, i) => i + 1).map((month) => (
                <option key={month} value={month}>
                  {new Date(2000, month - 1, 1).toLocaleString("en-US", { month: "long" })}
                </option>
              ))}
            </select>
          </fieldset>
          <fieldset
            style={complianceInfo.country !== "US" ? { gridRow: 1, gridColumn: 1 } : {}}
            className={cx({ danger: errorFieldNames.has("dob_day") })}
          >
            <select
              id={`${uid}-creator-dob-day`}
              disabled={isFormDisabled}
              required
              aria-label="Day"
              aria-invalid={errorFieldNames.has("dob_day")}
              value={complianceInfo.dob_day || "Day"}
              onChange={(evt) => updateComplianceInfo({ dob_day: Number(evt.target.value) })}
            >
              <option disabled>Day</option>
              {Array.from({ length: 31 }, (_, i) => i + 1).map((day) => (
                <option key={day} value={day}>
                  {day}
                </option>
              ))}
            </select>
          </fieldset>
          <fieldset className={cx({ danger: errorFieldNames.has("dob_year") })}>
            <select
              id={`${uid}-creator-dob-year`}
              disabled={isFormDisabled}
              required
              aria-label="Year"
              aria-invalid={errorFieldNames.has("dob_year")}
              value={complianceInfo.dob_year || "Year"}
              onChange={(evt) => updateComplianceInfo({ dob_year: Number(evt.target.value) })}
            >
              <option disabled>Year</option>
              {Array.from({ length: minDobYear - 1900 }, (_, i) => i + 1900).map((year) => (
                <option key={year} value={year}>
                  {year}
                </option>
              ))}
            </select>
          </fieldset>
        </div>
      </fieldset>
      {showNationalityField ? (
        <fieldset className={cx({ danger: errorFieldNames.has("nationality") })}>
          <legend>
            <label htmlFor={`${uid}-nationality`}>Nationality</label>
          </legend>
          <div>
            <select
              id={`${uid}-nationality`}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("nationality")}
              value={complianceInfo.nationality || "Nationality"}
              onChange={(evt) => updateComplianceInfo({ nationality: evt.target.value })}
            >
              <option disabled>Nationality</option>
              {Object.entries(countries).map(([code, name]) => (
                <option key={code} value={code} disabled={name.includes("(not supported)")}>
                  {name}
                </option>
              ))}
            </select>
          </div>
        </fieldset>
      ) : null}
      {needsIndividualTaxId && individualTaxIdConfig ? (
        <fieldset className={cx({ danger: errorFieldNames.has("individual_tax_id") })}>
          <div>
            <legend>
              <label htmlFor={`${uid}-${individualTaxIdConfig.idSuffix}`}>{individualTaxIdConfig.label}</label>
            </legend>
            <input
              id={`${uid}-${individualTaxIdConfig.idSuffix}`}
              type="text"
              minLength={individualTaxIdConfig.minLength}
              maxLength={individualTaxIdConfig.maxLength}
              placeholder={user.individual_tax_id_entered ? "Hidden for security" : individualTaxIdConfig.placeholder}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("individual_tax_id")}
              onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
            />
          </div>
        </fieldset>
      ) : null}
    </section>
  );
};
export default AccountDetailsSection;
