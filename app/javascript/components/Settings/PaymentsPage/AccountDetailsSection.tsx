import parsePhoneNumberFromString, { CountryCode } from "libphonenumber-js";
import * as React from "react";
import { cast } from "ts-safe-cast";

import type { ComplianceInfo, FormFieldName, User } from "$app/types/payments";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";
import { Tab, Tabs } from "$app/components/ui/Tabs";

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
    const configs: Record<string, { label: string; placeholder: string; minLength?: number; maxLength?: number }> = {
      US: {
        label: "Business Tax ID (EIN, or SSN for sole proprietors)",
        placeholder: "12-3456789",
        minLength: 9,
        maxLength: 10,
      },
      CA: { label: "Business Number (BN)", placeholder: "123456789" },
      AU: { label: "Australian Business Number (ABN)", placeholder: "12 123 456 789" },
      GB: { label: "Company Number (CRN)", placeholder: "12345678" },
      MX: { label: "Business RFC", placeholder: "12345678" },
    };

    const config = complianceInfo.business_country ? configs[complianceInfo.business_country] : null;
    return {
      label: config?.label ?? "Company tax ID",
      placeholder: config?.placeholder ?? "12345678",
      ...(config?.minLength != null && { minLength: config.minLength }),
      ...(config?.maxLength != null && { maxLength: config.maxLength }),
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
        <Fieldset state={errorFieldNames.has(fieldName) ? "danger" : undefined}>
          <FieldsetTitle>
            <Label htmlFor={`${uid}-${config.idSuffix}`}>{config.label}</Label>
          </FieldsetTitle>
          <Select
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
          </Select>
        </Fieldset>
      );
    }

    return (
      <Fieldset state={errorFieldNames.has(fieldName) ? "danger" : undefined}>
        <FieldsetTitle>
          <Label htmlFor={`${uid}-${config.idSuffix}`}>{config.label}</Label>
        </FieldsetTitle>
        <Select
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
        </Select>
      </Fieldset>
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
          <Fieldset>
            <FieldsetTitle>
              <Label>Account type</Label>
              <a href="/help/article/260-your-payout-settings-page">What type of account should I choose?</a>
            </FieldsetTitle>
          </Fieldset>
          <Tabs variant="buttons" className="grid-cols-1 gap-4 sm:grid-cols-2" role="radiogroup">
            <Tab key="individual" isSelected={!complianceInfo.is_business} asChild>
              <Button
                role="radio"
                aria-checked={!complianceInfo.is_business}
                onClick={() => updateComplianceInfo({ is_business: false })}
                disabled={isFormDisabled}
                className="items-start justify-start text-left"
              >
                <Icon name="person" />
                <div>
                  <h4 className="font-bold">Individual</h4>
                  When you are selling as yourself
                </div>
              </Button>
            </Tab>
            <Tab key="business" isSelected={complianceInfo.is_business} asChild>
              <Button
                role="radio"
                aria-checked={complianceInfo.is_business}
                onClick={() =>
                  updateComplianceInfo({
                    is_business: true,
                    business_country: complianceInfo.business_country ?? complianceInfo.country,
                  })
                }
                disabled={isFormDisabled}
                className="items-start justify-start text-left"
              >
                <Icon name="shop-window" />
                <div>
                  <h4 className="font-bold">Business</h4>
                  When you are selling as a business
                </div>
              </Button>
            </Tab>
          </Tabs>
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
            <Fieldset state={errorFieldNames.has("business_name") ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-business-legal-name`}>
                  {complianceInfo.business_country === "JP" ? "Legal business name (Romaji)" : "Legal business name"}
                </Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-business-legal-name`}
                placeholder="Acme"
                required={complianceInfo.is_business}
                value={complianceInfo.business_name || ""}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("business_name")}
                onChange={(evt) => updateComplianceInfo({ business_name: evt.target.value })}
              />
            </Fieldset>
            <Fieldset state={errorFieldNames.has("business_type") ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-business-type`}>Type</Label>
              </FieldsetTitle>
              {businessTypes ? (
                <Select
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
                </Select>
              ) : (
                <Select
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
                </Select>
              )}
            </Fieldset>
          </div>
          {complianceInfo.business_country === "JP" ? (
            <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
              <Fieldset state={errorFieldNames.has("business_name_kanji") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-business-name-kanji`}>Business Name (Kanji)</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-business-name-kanji`}
                  type="text"
                  placeholder="Legal Business Name (Kanji)"
                  value={complianceInfo.business_name_kanji || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_name_kanji")}
                  required
                  onChange={(evt) => updateComplianceInfo({ business_name_kanji: evt.target.value })}
                />
              </Fieldset>
              <Fieldset state={errorFieldNames.has("business_name_kana") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-business-name-kana`}>Legal Business Name (Kana)</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-business-name-kana`}
                  type="text"
                  placeholder="カタカナ"
                  value={complianceInfo.business_name_kana || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_name_kana")}
                  required
                  onChange={(evt) => updateComplianceInfo({ business_name_kana: evt.target.value })}
                />
              </Fieldset>
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
                <Fieldset state={errorFieldNames.has("business_building_number") ? "danger" : undefined}>
                  <FieldsetTitle>
                    <Label htmlFor={`${uid}-business-building-number`}>Block / Building number</Label>
                  </FieldsetTitle>
                  <Input
                    id={`${uid}-business-building-number`}
                    type="text"
                    placeholder="1-1"
                    value={complianceInfo.business_building_number || ""}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_building_number")}
                    required
                    onChange={(evt) => updateComplianceInfo({ business_building_number: evt.target.value })}
                  />
                </Fieldset>
                <Fieldset state={errorFieldNames.has("business_building_number_kana") ? "danger" : undefined}>
                  <FieldsetTitle>
                    <Label htmlFor={`${uid}-business-building-number-kana`}>Block / Building number (Kana)</Label>
                  </FieldsetTitle>
                  <Input
                    id={`${uid}-business-building-number-kana`}
                    type="text"
                    placeholder="イチノイチ"
                    value={complianceInfo.business_building_number_kana || ""}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_building_number_kana")}
                    required
                    onChange={(evt) => updateComplianceInfo({ business_building_number_kana: evt.target.value })}
                  />
                </Fieldset>
              </div>
              <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
                <Fieldset state={errorFieldNames.has("business_street_address_kanji") ? "danger" : undefined}>
                  <FieldsetTitle>
                    <Label htmlFor={`${uid}-business-street-address-kanji`}>Business town/Cho-me (Kanji)</Label>
                  </FieldsetTitle>
                  <Input
                    id={`${uid}-business-street-address-kanji`}
                    type="text"
                    placeholder="千代田"
                    value={complianceInfo.business_street_address_kanji || ""}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_street_address_kanji")}
                    required
                    onChange={(evt) => updateComplianceInfo({ business_street_address_kanji: evt.target.value })}
                  />
                </Fieldset>
                <Fieldset state={errorFieldNames.has("business_street_address_kana") ? "danger" : undefined}>
                  <FieldsetTitle>
                    <Label htmlFor={`${uid}-business-street-address-kana`}>Business town/Cho-me (Kana)</Label>
                  </FieldsetTitle>
                  <Input
                    id={`${uid}-business-street-address-kana`}
                    type="text"
                    placeholder="チヨダ"
                    value={complianceInfo.business_street_address_kana || ""}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_street_address_kana")}
                    required
                    onChange={(evt) => updateComplianceInfo({ business_street_address_kana: evt.target.value })}
                  />
                </Fieldset>
              </div>
            </>
          ) : (
            <Fieldset state={errorFieldNames.has("business_street_address") ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-business-street-address`}>Address</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-business-street-address`}
                placeholder="123 smith street"
                value={complianceInfo.business_street_address || ""}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("business_street_address")}
                onChange={(evt) => updateComplianceInfo({ business_street_address: evt.target.value })}
              />
            </Fieldset>
          )}
          <div
            style={{
              display: "grid",
              gap: "var(--spacer-5)",
              gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
            }}
          >
            <Fieldset state={errorFieldNames.has("business_city") ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-business-city`}>City</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-business-city`}
                placeholder="Springfield"
                value={complianceInfo.business_city || ""}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("business_city")}
                onChange={(evt) => updateComplianceInfo({ business_city: evt.target.value })}
              />
            </Fieldset>
            {businessStateConfig
              ? renderStateSelect(
                  businessStateConfig,
                  complianceInfo.business_state,
                  (value) => updateComplianceInfo({ business_state: value }),
                  "business_state",
                )
              : null}
            <Fieldset state={errorFieldNames.has("business_zip_code") ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-business-zip-code`}>
                  {complianceInfo.business_country === "US" ? "ZIP code" : "Postal code"}
                </Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-business-zip-code`}
                placeholder="12345"
                required={complianceInfo.is_business}
                value={complianceInfo.business_zip_code || ""}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("business_zip_code")}
                onChange={(evt) => updateComplianceInfo({ business_zip_code: evt.target.value })}
              />
            </Fieldset>
          </div>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-business-country`}>Country</Label>
            </FieldsetTitle>
            <Select
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
            </Select>
          </Fieldset>
          <Fieldset state={errorFieldNames.has("business_phone") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-business-phone-number`}>Business phone number</Label>
            </FieldsetTitle>
            <Input
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
          </Fieldset>
          {user.country_supports_native_payouts || complianceInfo.business_country === "AE" ? (
            <Fieldset state={errorFieldNames.has("business_tax_id") ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-${businessTaxIdConfig.idSuffix}`}>{businessTaxIdConfig.label}</Label>
                {complianceInfo.business_country === "US" ? (
                  <div className="small">
                    <a href="/help/article/260-your-payout-settings-page">I'm not sure what my Tax ID is.</a>
                  </div>
                ) : null}
              </FieldsetTitle>
              <Input
                id={`${uid}-${businessTaxIdConfig.idSuffix}`}
                type="text"
                placeholder={user.business_tax_id_entered ? "Hidden for security" : businessTaxIdConfig.placeholder}
                minLength={businessTaxIdConfig.minLength}
                maxLength={businessTaxIdConfig.maxLength}
                required={complianceInfo.is_business}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("business_tax_id")}
                onChange={(evt) => updateComplianceInfo({ business_tax_id: evt.target.value })}
              />
            </Fieldset>
          ) : null}
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-personal-address-is-business-address`}>
                <Checkbox
                  id={`${uid}-personal-address-is-business-address`}
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
              </Label>
            </FieldsetTitle>
          </Fieldset>
        </section>
      ) : null}
      <section className="grid gap-8">
        <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
          <Fieldset state={errorFieldNames.has("first_name") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-first-name`}>First name</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-creator-first-name`}
              type="text"
              placeholder="First name"
              value={complianceInfo.first_name || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("first_name")}
              required
              onChange={(evt) => updateComplianceInfo({ first_name: evt.target.value })}
            />
            <FieldsetDescription>Include your middle name if it appears on your ID.</FieldsetDescription>
          </Fieldset>
          <Fieldset state={errorFieldNames.has("last_name") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-last-name`}>Last name</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-creator-last-name`}
              type="text"
              placeholder="Last name"
              value={complianceInfo.last_name || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("last_name")}
              required
              onChange={(evt) => updateComplianceInfo({ last_name: evt.target.value })}
            />
          </Fieldset>
        </div>
        {complianceInfo.is_business && complianceInfo.country === "CA" ? (
          <Fieldset state={errorFieldNames.has("job_title") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-job-title`}>Job title</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-creator-job-title`}
              type="text"
              placeholder="CEO"
              value={complianceInfo.job_title || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("job_title")}
              required
              onChange={(evt) => updateComplianceInfo({ job_title: evt.target.value })}
            />
          </Fieldset>
        ) : null}
        {complianceInfo.country === "JP" ? (
          <>
            <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
              <Fieldset state={errorFieldNames.has("first_name_kanji") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-creator-first-name-kanji`}>First name (Kanji)</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-creator-first-name-kanji`}
                  type="text"
                  placeholder="First name (Kanji)"
                  value={complianceInfo.first_name_kanji || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("first_name_kanji")}
                  required
                  onChange={(evt) => updateComplianceInfo({ first_name_kanji: evt.target.value })}
                />
              </Fieldset>
              <Fieldset state={errorFieldNames.has("last_name_kanji") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-creator-last-name-kanji`}>Last name (Kanji)</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-creator-last-name-kanji`}
                  type="text"
                  placeholder="Last name (Kanji)"
                  value={complianceInfo.last_name_kanji || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("last_name_kanji")}
                  required
                  onChange={(evt) => updateComplianceInfo({ last_name_kanji: evt.target.value })}
                />
              </Fieldset>
            </div>
            <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
              <Fieldset state={errorFieldNames.has("first_name_kana") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-creator-first-name-kana`}>First name (Kana)</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-creator-first-name-kana`}
                  type="text"
                  placeholder="カタカナ"
                  value={complianceInfo.first_name_kana || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("first_name_kana")}
                  required
                  onChange={(evt) => updateComplianceInfo({ first_name_kana: evt.target.value })}
                />
              </Fieldset>
              <Fieldset state={errorFieldNames.has("last_name_kana") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-creator-last-name-kana`}>Last name (Kana)</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-creator-last-name-kana`}
                  type="text"
                  placeholder="カタカナ"
                  value={complianceInfo.last_name_kana || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("last_name_kana")}
                  required
                  onChange={(evt) => updateComplianceInfo({ last_name_kana: evt.target.value })}
                />
              </Fieldset>
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
              <Fieldset state={errorFieldNames.has("building_number") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-creator-building-number`}>Block / Building number</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-creator-building-number`}
                  type="text"
                  placeholder="1-1"
                  value={complianceInfo.building_number || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("building_number")}
                  required
                  onChange={(evt) => updateComplianceInfo({ building_number: evt.target.value })}
                />
              </Fieldset>
              <Fieldset state={errorFieldNames.has("building_number_kana") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-creator-building-number-kana`}>Block / Building number (Kana)</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-creator-building-number-kana`}
                  type="text"
                  placeholder="イチノイチ"
                  value={complianceInfo.building_number_kana || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("building_number_kana")}
                  required
                  onChange={(evt) => updateComplianceInfo({ building_number_kana: evt.target.value })}
                />
              </Fieldset>
            </div>
            <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
              <Fieldset state={errorFieldNames.has("street_address_kanji") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-creator-street-address-kanji`}>Town/Cho-me (Kanji)</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-creator-street-address-kanji`}
                  type="text"
                  placeholder="千代田"
                  value={complianceInfo.street_address_kanji || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("street_address_kanji")}
                  required
                  onChange={(evt) => updateComplianceInfo({ street_address_kanji: evt.target.value })}
                />
              </Fieldset>
              <Fieldset state={errorFieldNames.has("street_address_kana") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-creator-street-address-kana`}>Town/Cho-me (Kana)</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-creator-street-address-kana`}
                  type="text"
                  placeholder="チヨダ"
                  value={complianceInfo.street_address_kana || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("street_address_kana")}
                  required
                  onChange={(evt) => updateComplianceInfo({ street_address_kana: evt.target.value })}
                />
              </Fieldset>
            </div>
          </>
        ) : (
          <Fieldset state={errorFieldNames.has("street_address") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-street-address`}>Address</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-creator-street-address`}
              type="text"
              placeholder="Street address"
              required
              value={complianceInfo.street_address || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("street_address")}
              onChange={(evt) => updateComplianceInfo({ street_address: evt.target.value })}
            />
          </Fieldset>
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
          <Fieldset state={errorFieldNames.has("state") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-prefecture`}>Prefecture</Label>
            </FieldsetTitle>
            <Select
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
            </Select>
          </Fieldset>
          <Fieldset state={errorFieldNames.has("zip_code") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-zip-code`}>Postal code</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-creator-zip-code`}
              type="text"
              placeholder="100-0000"
              value={complianceInfo.zip_code || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("zip_code")}
              required
              onChange={(evt) => updateComplianceInfo({ zip_code: evt.target.value })}
            />
          </Fieldset>
        </div>
      ) : (
        <div
          style={{
            display: "grid",
            gap: "var(--spacer-5)",
            gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
          }}
        >
          <Fieldset state={errorFieldNames.has("city") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-city`}>City</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-creator-city`}
              type="text"
              placeholder="City"
              value={complianceInfo.city || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("city")}
              required
              onChange={(evt) => updateComplianceInfo({ city: evt.target.value })}
            />
          </Fieldset>
          {individualStateConfig
            ? renderStateSelect(
                individualStateConfig,
                complianceInfo.state,
                (value) => updateComplianceInfo({ state: value }),
                "state",
              )
            : null}
          <Fieldset state={errorFieldNames.has("zip_code") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-zip-code`}>
                {complianceInfo.country === "US" ? "ZIP code" : "Postal code"}
              </Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-creator-zip-code`}
              type="text"
              placeholder={complianceInfo.country === "US" ? "ZIP code" : "Postal code"}
              value={complianceInfo.zip_code || ""}
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("zip_code")}
              required
              onChange={(evt) => updateComplianceInfo({ zip_code: evt.target.value })}
            />
          </Fieldset>
        </div>
      )}
      <Fieldset>
        <FieldsetTitle>
          <Label htmlFor={`${uid}-creator-country`}>Country</Label>
        </FieldsetTitle>
        <Select
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
        </Select>
      </Fieldset>
      <Fieldset state={errorFieldNames.has("phone") ? "danger" : undefined}>
        <FieldsetTitle>
          <Label htmlFor={`${uid}-creator-phone`}>Phone number</Label>
        </FieldsetTitle>
        <Input
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
      </Fieldset>
      <Fieldset>
        <FieldsetTitle>
          <Label>Date of Birth</Label>
          <a href="/help/article/260-your-payout-settings-page">Why does Gumroad need this information?</a>
        </FieldsetTitle>
        <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
          <Fieldset state={errorFieldNames.has("dob_month") ? "danger" : undefined}>
            <Select
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
            </Select>
          </Fieldset>
          <Fieldset
            style={complianceInfo.country !== "US" ? { gridRow: 1, gridColumn: 1 } : {}}
            state={errorFieldNames.has("dob_day") ? "danger" : undefined}
          >
            <Select
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
            </Select>
          </Fieldset>
          <Fieldset state={errorFieldNames.has("dob_year") ? "danger" : undefined}>
            <Select
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
            </Select>
          </Fieldset>
        </div>
      </Fieldset>
      {showNationalityField ? (
        <Fieldset state={errorFieldNames.has("nationality") ? "danger" : undefined}>
          <FieldsetTitle>
            <Label htmlFor={`${uid}-nationality`}>Nationality</Label>
          </FieldsetTitle>
          <div>
            <Select
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
            </Select>
          </div>
        </Fieldset>
      ) : null}
      {needsIndividualTaxId && individualTaxIdConfig ? (
        <Fieldset state={errorFieldNames.has("individual_tax_id") ? "danger" : undefined}>
          <div>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-${individualTaxIdConfig.idSuffix}`}>{individualTaxIdConfig.label}</Label>
            </FieldsetTitle>
            <Input
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
        </Fieldset>
      ) : null}
    </section>
  );
};
export default AccountDetailsSection;
