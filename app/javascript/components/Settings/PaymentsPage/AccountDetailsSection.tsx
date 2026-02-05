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
  };
  errorFieldNames: Set<FormFieldName>;
}) => {
  const uid = React.useId();

  const formatPhoneNumber = (phoneNumber: string, country_code: string | null) => {
    const countryCode: CountryCode = cast(country_code);
    return parsePhoneNumberFromString(phoneNumber, countryCode)?.format("E.164") ?? phoneNumber;
  };

  return (
    <section className="grid gap-8">
      {(complianceInfo.is_business ? complianceInfo.business_country !== "AE" : complianceInfo.country !== "AE") ? (
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
                <Label htmlFor={`${uid}-business-legal-name`}>Legal business name</Label>
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
              {complianceInfo.business_country === "AE" ? (
                <Select
                  id={`${uid}-business-type`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_type")}
                  value={complianceInfo.business_type || "Type"}
                  onChange={(evt) => updateComplianceInfo({ business_type: evt.target.value })}
                >
                  <option disabled>Type</option>
                  {uaeBusinessTypes.map((businessType) => (
                    <option key={businessType.code} value={businessType.code}>
                      {businessType.name}
                    </option>
                  ))}
                </Select>
              ) : complianceInfo.business_country === "IN" ? (
                <Select
                  id={`${uid}-business-type`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_type")}
                  value={complianceInfo.business_type || "Type"}
                  onChange={(evt) => updateComplianceInfo({ business_type: evt.target.value })}
                >
                  <option disabled>Type</option>
                  {indiaBusinessTypes.map((businessType) => (
                    <option key={businessType.code} value={businessType.code}>
                      {businessType.name}
                    </option>
                  ))}
                </Select>
              ) : complianceInfo.business_country === "CA" ? (
                <Select
                  id={`${uid}-business-type`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_type")}
                  value={complianceInfo.business_type || "Type"}
                  onChange={(evt) => updateComplianceInfo({ business_type: evt.target.value })}
                >
                  <option disabled>Type</option>
                  {canadaBusinessTypes.map((businessType) => (
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
                  placeholder="Business Name (Kana)"
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
            <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
              <Fieldset state={errorFieldNames.has("business_building_number") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-business-building-number`}>Business Block / Building Number</Label>
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
              <Fieldset state={errorFieldNames.has("business_street_address_kanji") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-business-street-address-kanji`}>Business Street Address (Kanji)</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-business-street-address-kanji`}
                  type="text"
                  placeholder="Business Street Address (Kanji)"
                  value={complianceInfo.business_street_address_kanji || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_street_address_kanji")}
                  required
                  onChange={(evt) => updateComplianceInfo({ business_street_address_kanji: evt.target.value })}
                />
              </Fieldset>
              <Fieldset state={errorFieldNames.has("business_street_address_kana") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-business-street-address-kana`}>Business Street Address (Kana)</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-business-street-address-kana`}
                  type="text"
                  placeholder="Business Street Address (Kana)"
                  value={complianceInfo.business_street_address_kana || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_street_address_kana")}
                  required
                  onChange={(evt) => updateComplianceInfo({ business_street_address_kana: evt.target.value })}
                />
              </Fieldset>
            </div>
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
            {complianceInfo.business_country === "US" ? (
              <Fieldset state={errorFieldNames.has("business_state") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-business-state`}>State</Label>
                </FieldsetTitle>
                <Select
                  id={`${uid}-business-state`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_state")}
                  value={complianceInfo.business_state || ""}
                  onChange={(evt) => updateComplianceInfo({ business_state: evt.target.value })}
                >
                  <option value="" disabled>
                    State
                  </option>
                  {states.us.map((state) => (
                    <option key={state.code} value={state.code}>
                      {state.name}
                    </option>
                  ))}
                </Select>
              </Fieldset>
            ) : complianceInfo.business_country === "CA" ? (
              <Fieldset state={errorFieldNames.has("business_state") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-business-province`}>Province</Label>
                </FieldsetTitle>
                <Select
                  id={`${uid}-business-province`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_state")}
                  value={complianceInfo.business_state || ""}
                  onChange={(evt) => updateComplianceInfo({ business_state: evt.target.value })}
                >
                  <option value="" disabled>
                    Province
                  </option>
                  {states.ca.map((state) => (
                    <option key={state.code} value={state.code}>
                      {state.name}
                    </option>
                  ))}
                </Select>
              </Fieldset>
            ) : complianceInfo.business_country === "AU" ? (
              <Fieldset state={errorFieldNames.has("business_state") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-business-state`}>State</Label>
                </FieldsetTitle>
                <Select
                  id={`${uid}-business-state`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_state")}
                  value={complianceInfo.business_state || ""}
                  onChange={(evt) => updateComplianceInfo({ business_state: evt.target.value })}
                >
                  <option value="" disabled>
                    State
                  </option>
                  {states.au.map((state) => (
                    <option key={state.code} value={state.code}>
                      {state.name}
                    </option>
                  ))}
                </Select>
              </Fieldset>
            ) : complianceInfo.business_country === "MX" ? (
              <Fieldset state={errorFieldNames.has("business_state") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-business-state`}>State</Label>
                </FieldsetTitle>
                <Select
                  id={`${uid}-business-state`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_state")}
                  value={complianceInfo.business_state || ""}
                  onChange={(evt) => updateComplianceInfo({ business_state: evt.target.value })}
                >
                  <option value="" disabled>
                    State
                  </option>
                  {states.mx.map((state) => (
                    <option key={state.code} value={state.code}>
                      {state.name}
                    </option>
                  ))}
                </Select>
              </Fieldset>
            ) : complianceInfo.business_country === "AE" ? (
              <Fieldset state={errorFieldNames.has("business_state") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-business-state`}>Province</Label>
                </FieldsetTitle>
                <Select
                  id={`${uid}-business-state`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_state")}
                  value={complianceInfo.business_state || ""}
                  onChange={(evt) => updateComplianceInfo({ business_state: evt.target.value })}
                >
                  <option value="" disabled>
                    Province
                  </option>
                  {states.ae.map((state) => (
                    <option key={state.code} value={state.code}>
                      {state.name}
                    </option>
                  ))}
                </Select>
              </Fieldset>
            ) : complianceInfo.business_country === "IE" ? (
              <Fieldset state={errorFieldNames.has("business_state") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-business-county`}>County</Label>
                </FieldsetTitle>
                <Select
                  id={`${uid}-business-county`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_state")}
                  value={complianceInfo.business_state || ""}
                  onChange={(evt) => updateComplianceInfo({ business_state: evt.target.value })}
                >
                  <option value="" disabled>
                    County
                  </option>
                  {states.ir.map((state) => (
                    <option key={state.code} value={state.code}>
                      {state.name}
                    </option>
                  ))}
                </Select>
              </Fieldset>
            ) : null}
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
              {complianceInfo.business_country === "US" ? (
                <>
                  <FieldsetTitle>
                    <Label htmlFor={`${uid}-business-tax-id`}>Business Tax ID (EIN, or SSN for sole proprietors)</Label>
                    <div className="small">
                      <a href="/help/article/260-your-payout-settings-page">I'm not sure what my Tax ID is.</a>
                    </div>
                  </FieldsetTitle>
                  <Input
                    id={`${uid}-business-tax-id`}
                    type="text"
                    placeholder={user.business_tax_id_entered ? "Hidden for security" : "12-3456789"}
                    required={complianceInfo.is_business}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_tax_id")}
                    onChange={(evt) => updateComplianceInfo({ business_tax_id: evt.target.value })}
                  />
                </>
              ) : complianceInfo.business_country === "CA" ? (
                <>
                  <FieldsetTitle>
                    <Label htmlFor={`${uid}-business-tax-id`}>Business Number (BN)</Label>
                  </FieldsetTitle>
                  <Input
                    id={`${uid}-business-tax-id`}
                    type="text"
                    placeholder={user.business_tax_id_entered ? "Hidden for security" : "123456789"}
                    required={complianceInfo.is_business}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_tax_id")}
                    onChange={(evt) => updateComplianceInfo({ business_tax_id: evt.target.value })}
                  />
                </>
              ) : complianceInfo.business_country === "AU" ? (
                <>
                  <FieldsetTitle>
                    <Label htmlFor={`${uid}-business-tax-id`}>Australian Business Number (ABN)</Label>
                  </FieldsetTitle>
                  <Input
                    id={`${uid}-business-tax-id`}
                    type="text"
                    placeholder={user.business_tax_id_entered ? "Hidden for security" : "12 123 456 789"}
                    required={complianceInfo.is_business}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_tax_id")}
                    onChange={(evt) => updateComplianceInfo({ business_tax_id: evt.target.value })}
                  />
                </>
              ) : complianceInfo.business_country === "GB" ? (
                <>
                  <FieldsetTitle>
                    <Label htmlFor={`${uid}-business-tax-id`}>Company Number (CRN)</Label>
                  </FieldsetTitle>
                  <Input
                    id={`${uid}-business-tax-id`}
                    type="text"
                    placeholder={user.business_tax_id_entered ? "Hidden for security" : "12345678"}
                    required={complianceInfo.is_business}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_tax_id")}
                    onChange={(evt) => updateComplianceInfo({ business_tax_id: evt.target.value })}
                  />
                </>
              ) : complianceInfo.business_country === "AE" ? (
                <>
                  <FieldsetTitle>
                    <Label htmlFor={`${uid}-business-tax-id`}>Company tax ID</Label>
                  </FieldsetTitle>
                  <Input
                    id={`${uid}-business-tax-id`}
                    type="text"
                    placeholder={user.business_tax_id_entered ? "Hidden for security" : "12345678"}
                    required={complianceInfo.is_business}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_tax_id")}
                    onChange={(evt) => updateComplianceInfo({ business_tax_id: evt.target.value })}
                  />
                </>
              ) : complianceInfo.business_country === "MX" ? (
                <>
                  <FieldsetTitle>
                    <Label htmlFor={`${uid}-business-tax-id`}>Business RFC</Label>
                  </FieldsetTitle>
                  <Input
                    id={`${uid}-business-tax-id`}
                    type="text"
                    placeholder={user.business_tax_id_entered ? "Hidden for security" : "12345678"}
                    required={complianceInfo.is_business}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_tax_id")}
                    onChange={(evt) => updateComplianceInfo({ business_tax_id: evt.target.value })}
                  />
                </>
              ) : (
                <>
                  <FieldsetTitle>
                    <Label htmlFor={`${uid}-business-tax-id`}>Company tax ID</Label>
                  </FieldsetTitle>
                  <Input
                    id={`${uid}-business-tax-id`}
                    type="text"
                    placeholder={user.business_tax_id_entered ? "Hidden for security" : "12345678"}
                    required={complianceInfo.is_business}
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("business_tax_id")}
                    onChange={(evt) => updateComplianceInfo({ business_tax_id: evt.target.value })}
                  />
                </>
              )}
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
                  placeholder="First name (Kana)"
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
                  placeholder="Last name (Kana)"
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
          <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
            <Fieldset state={errorFieldNames.has("building_number") ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-creator-building-number`}>Block / Building Number</Label>
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
            <Fieldset state={errorFieldNames.has("street_address_kanji") ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-creator-street-address-kanji`}>Street Address (Kanji)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-creator-street-address-kanji`}
                type="text"
                placeholder="Street Address (Kanji)"
                value={complianceInfo.street_address_kanji || ""}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("street_address_kanji")}
                required
                onChange={(evt) => updateComplianceInfo({ street_address_kanji: evt.target.value })}
              />
            </Fieldset>
            <Fieldset state={errorFieldNames.has("street_address_kana") ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-creator-street-address-kana`}>Street Address (Kana)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-creator-street-address-kana`}
                type="text"
                placeholder="Street Address (Kana)"
                value={complianceInfo.street_address_kana || ""}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("street_address_kana")}
                required
                onChange={(evt) => updateComplianceInfo({ street_address_kana: evt.target.value })}
              />
            </Fieldset>
          </div>
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
      <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
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
        {complianceInfo.country === "US" ? (
          <Fieldset state={errorFieldNames.has("state") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-state`}>State</Label>
            </FieldsetTitle>
            <Select
              id={`${uid}-creator-state`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || ""}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option value="" disabled>
                State
              </option>
              {states.us.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </Select>
          </Fieldset>
        ) : complianceInfo.country === "CA" ? (
          <Fieldset state={errorFieldNames.has("state") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-province`}>Province</Label>
            </FieldsetTitle>
            <Select
              id={`${uid}-creator-province`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || ""}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option value="" disabled>
                Province
              </option>
              {states.ca.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </Select>
          </Fieldset>
        ) : complianceInfo.country === "AU" ? (
          <Fieldset state={errorFieldNames.has("state") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-state`}>State</Label>
            </FieldsetTitle>
            <Select
              id={`${uid}-creator-state`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || ""}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option value="" disabled>
                State
              </option>
              {states.au.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </Select>
          </Fieldset>
        ) : complianceInfo.country === "MX" ? (
          <Fieldset state={errorFieldNames.has("state") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-state`}>State</Label>
            </FieldsetTitle>
            <Select
              id={`${uid}-creator-state`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || ""}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option value="" disabled>
                State
              </option>
              {states.mx.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </Select>
          </Fieldset>
        ) : complianceInfo.country === "AE" ? (
          <Fieldset state={errorFieldNames.has("state") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-province`}>Province</Label>
            </FieldsetTitle>
            <Select
              id={`${uid}-creator-province`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || ""}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option value="" disabled>
                Province
              </option>
              {states.ae.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </Select>
          </Fieldset>
        ) : complianceInfo.country === "IE" ? (
          <Fieldset state={errorFieldNames.has("state") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-county`}>County</Label>
            </FieldsetTitle>
            <Select
              id={`${uid}-creator-county`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || ""}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option value="" disabled>
                County
              </option>
              {states.ir.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </Select>
          </Fieldset>
        ) : complianceInfo.country === "BR" ? (
          <Fieldset state={errorFieldNames.has("state") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-creator-state`}>State</Label>
            </FieldsetTitle>
            <Select
              id={`${uid}-creator-state`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || ""}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option value="" disabled>
                State
              </option>
              {states.br.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </Select>
          </Fieldset>
        ) : null}
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
      {user.country_code === "AE" ||
      user.country_code === "SG" ||
      user.country_code === "PK" ||
      user.country_code === "BD" ? (
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
      {(complianceInfo.is_business &&
        complianceInfo.business_country !== null &&
        user.individual_tax_id_needed_countries.includes(complianceInfo.business_country)) ||
      (complianceInfo.country !== null && user.individual_tax_id_needed_countries.includes(complianceInfo.country)) ? (
        <Fieldset state={errorFieldNames.has("individual_tax_id") ? "danger" : undefined}>
          {complianceInfo.country === "US" ? (
            user.need_full_ssn ? (
              <div>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-social-security-number-full`}>Social Security Number</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-social-security-number-full`}
                  type="text"
                  minLength={9}
                  maxLength={11}
                  placeholder={user.individual_tax_id_entered ? "Hidden for security" : "•••-••-••••"}
                  required
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("individual_tax_id")}
                  onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
                />
              </div>
            ) : (
              <div>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-social-security-number`}>Last 4 digits of SSN</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-social-security-number`}
                  type="text"
                  minLength={4}
                  maxLength={4}
                  placeholder={user.individual_tax_id_entered ? "Hidden for security" : "••••"}
                  required
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("individual_tax_id")}
                  onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
                />
              </div>
            )
          ) : complianceInfo.country === "CA" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-social-insurance-number`}>Social Insurance Number</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-social-insurance-number`}
                type="text"
                minLength={9}
                maxLength={9}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "•••••••••"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "CO" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-colombia-id-number`}>Cédula de Ciudadanía (CC)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-colombia-id-number`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "1.123.123.123"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "UY" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-uruguay-id-number`}>Cédula de Identidad (CI)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-uruguay-id-number`}
                type="text"
                minLength={11}
                maxLength={11}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "1.123.123-1"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "HK" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-hong-kong-id-number`}>Hong Kong ID Number</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-hong-kong-id-number`}
                type="text"
                minLength={8}
                maxLength={9}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "SG" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-singapore-id-number`}>NRIC number / FIN</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-singapore-id-number`}
                type="text"
                minLength={9}
                maxLength={9}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "AE" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-uae-id-number`}>Emirates ID</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-uae-id-number`}
                type="text"
                minLength={15}
                maxLength={15}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "123456789123456"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "MX" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-mexico-id-number`}>Personal RFC</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-mexico-id-number`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "1234567891234"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "KZ" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-kazakhstan-id-number`}>Individual identification number (IIN)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-kazakhstan-id-number`}
                type="text"
                minLength={9}
                maxLength={12}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "AR" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-argentina-id-number`}>CUIL</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-argentina-id-number`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "12-12345678-1"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "PE" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-peru-id-number`}>DNI number</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-peru-id-number`}
                type="text"
                minLength={10}
                maxLength={10}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "12345678-9"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "PK" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-snic`}>National Identity Card Number (SNIC or CNIC)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-snic`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "•••••••••"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "CR" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-costa-rica-id-number`}>Tax Identification Number</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-costa-rica-id-number`}
                type="text"
                minLength={9}
                maxLength={12}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "1234567890"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "CL" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-chile-id-number`}>Rol Único Tributario (RUT)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-chile-id-number`}
                type="text"
                minLength={8}
                maxLength={9}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "DO" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-dominican-republic-id-number`}>Cédula de identidad y electoral (CIE)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-dominican-republic-id-number`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "123-1234567-1"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "BO" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-bolivia-id-number`}>Cédula de Identidad (CI)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-bolivia-id-number`}
                type="text"
                minLength={8}
                maxLength={8}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "12345678"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "PY" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-paraguay-id-number`}>Cédula de Identidad (CI)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-paraguay-id-number`}
                type="text"
                minLength={7}
                maxLength={7}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "1234567"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "BD" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-bangladesh-id-number`}>Personal ID number</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-bangladesh-id-number`}
                type="text"
                minLength={1}
                maxLength={20}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "MZ" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-mozambique-id-number`}>Mozambique Taxpayer Single ID Number (NUIT)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-mozambique-id-number`}
                type="text"
                minLength={9}
                maxLength={9}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "GT" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-guatemala-id-number`}>Número de Identificación Tributaria (NIT)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-guatemala-id-number`}
                type="text"
                minLength={8}
                maxLength={12}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "1234567-8"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : complianceInfo.country === "BR" ? (
            <div>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-brazil-id-number`}>Cadastro de Pessoas Físicas (CPF)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-brazil-id-number`}
                type="text"
                minLength={11}
                maxLength={14}
                placeholder={user.individual_tax_id_entered ? "Hidden for security" : "123.456.789-00"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ individual_tax_id: evt.target.value })}
              />
            </div>
          ) : null}
        </Fieldset>
      ) : null}
    </section>
  );
};
export default AccountDetailsSection;
