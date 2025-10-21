import cx from "classnames";
import parsePhoneNumberFromString, { CountryCode } from "libphonenumber-js";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { ComplianceInfo, FormFieldName, User } from "$app/components/server-components/Settings/PaymentsPage";

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
              {complianceInfo.business_country === "AE" ? (
                <select
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
                </select>
              ) : complianceInfo.business_country === "IN" ? (
                <select
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
                </select>
              ) : complianceInfo.business_country === "CA" ? (
                <select
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
            <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
              <fieldset className={cx({ danger: errorFieldNames.has("business_building_number") })}>
                <legend>
                  <label htmlFor={`${uid}-business-building-number`}>Business Block / Building Number</label>
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
              <fieldset className={cx({ danger: errorFieldNames.has("business_street_address_kanji") })}>
                <legend>
                  <label htmlFor={`${uid}-business-street-address-kanji`}>Business Street Address (Kanji)</label>
                </legend>
                <input
                  id={`${uid}-business-street-address-kanji`}
                  type="text"
                  placeholder="Business Street Address (Kanji)"
                  value={complianceInfo.business_street_address_kanji || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_street_address_kanji")}
                  required
                  onChange={(evt) => updateComplianceInfo({ business_street_address_kanji: evt.target.value })}
                />
              </fieldset>
              <fieldset className={cx({ danger: errorFieldNames.has("business_street_address_kana") })}>
                <legend>
                  <label htmlFor={`${uid}-business-street-address-kana`}>Business Street Address (Kana)</label>
                </legend>
                <input
                  id={`${uid}-business-street-address-kana`}
                  type="text"
                  placeholder="Business Street Address (Kana)"
                  value={complianceInfo.business_street_address_kana || ""}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_street_address_kana")}
                  required
                  onChange={(evt) => updateComplianceInfo({ business_street_address_kana: evt.target.value })}
                />
              </fieldset>
            </div>
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
            {complianceInfo.business_country === "US" ? (
              <fieldset className={cx({ danger: errorFieldNames.has("business_state") })}>
                <legend>
                  <label htmlFor={`${uid}-business-state`}>State</label>
                </legend>
                <select
                  id={`${uid}-business-state`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_state")}
                  value={complianceInfo.business_state || "State"}
                  onChange={(evt) => updateComplianceInfo({ business_state: evt.target.value })}
                >
                  <option disabled>State</option>
                  {states.us.map((state) => (
                    <option key={state.code} value={state.code}>
                      {state.name}
                    </option>
                  ))}
                </select>
              </fieldset>
            ) : complianceInfo.business_country === "CA" ? (
              <fieldset className={cx({ danger: errorFieldNames.has("business_state") })}>
                <legend>
                  <label htmlFor={`${uid}-business-province`}>Province</label>
                </legend>
                <select
                  id={`${uid}-business-province`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_state")}
                  value={complianceInfo.business_state || "Province"}
                  onChange={(evt) => updateComplianceInfo({ business_state: evt.target.value })}
                >
                  <option disabled>Province</option>
                  {states.ca.map((state) => (
                    <option key={state.code} value={state.code}>
                      {state.name}
                    </option>
                  ))}
                </select>
              </fieldset>
            ) : complianceInfo.business_country === "AU" ? (
              <fieldset className={cx({ danger: errorFieldNames.has("business_state") })}>
                <legend>
                  <label htmlFor={`${uid}-business-state`}>State</label>
                </legend>
                <select
                  id={`${uid}-business-state`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_state")}
                  value={complianceInfo.business_state || "State"}
                  onChange={(evt) => updateComplianceInfo({ business_state: evt.target.value })}
                >
                  <option disabled>State</option>
                  {states.au.map((state) => (
                    <option key={state.code} value={state.code}>
                      {state.name}
                    </option>
                  ))}
                </select>
              </fieldset>
            ) : complianceInfo.business_country === "MX" ? (
              <fieldset className={cx({ danger: errorFieldNames.has("business_state") })}>
                <legend>
                  <label htmlFor={`${uid}-business-state`}>State</label>
                </legend>
                <select
                  id={`${uid}-business-state`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_state")}
                  value={complianceInfo.business_state || "State"}
                  onChange={(evt) => updateComplianceInfo({ business_state: evt.target.value })}
                >
                  <option disabled>State</option>
                  {states.mx.map((state) => (
                    <option key={state.code} value={state.code}>
                      {state.name}
                    </option>
                  ))}
                </select>
              </fieldset>
            ) : complianceInfo.business_country === "AE" ? (
              <fieldset className={cx({ danger: errorFieldNames.has("business_state") })}>
                <legend>
                  <label htmlFor={`${uid}-business-state`}>Province</label>
                </legend>
                <select
                  id={`${uid}-business-state`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_state")}
                  value={complianceInfo.business_state || "Province"}
                  onChange={(evt) => updateComplianceInfo({ business_state: evt.target.value })}
                >
                  <option disabled>Province</option>
                  {states.ae.map((state) => (
                    <option key={state.code} value={state.code}>
                      {state.name}
                    </option>
                  ))}
                </select>
              </fieldset>
            ) : complianceInfo.business_country === "IE" ? (
              <fieldset className={cx({ danger: errorFieldNames.has("business_state") })}>
                <legend>
                  <label htmlFor={`${uid}-business-county`}>County</label>
                </legend>
                <select
                  id={`${uid}-business-county`}
                  required={complianceInfo.is_business}
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("business_state")}
                  value={complianceInfo.business_state || "County"}
                  onChange={(evt) => updateComplianceInfo({ business_state: evt.target.value })}
                >
                  <option disabled>County</option>
                  {states.ir.map((state) => (
                    <option key={state.code} value={state.code}>
                      {state.name}
                    </option>
                  ))}
                </select>
              </fieldset>
            ) : null}
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
              {complianceInfo.business_country === "US" ? (
                <>
                  <legend>
                    <label htmlFor={`${uid}-business-tax-id`}>Business Tax ID (EIN, or SSN for sole proprietors)</label>
                    <div className="small">
                      <a href="/help/article/260-your-payout-settings-page">I'm not sure what my Tax ID is.</a>
                    </div>
                  </legend>
                  <input
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
                  <legend>
                    <label htmlFor={`${uid}-business-tax-id`}>Business Number (BN)</label>
                  </legend>
                  <input
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
                  <legend>
                    <label htmlFor={`${uid}-business-tax-id`}>Australian Business Number (ABN)</label>
                  </legend>
                  <input
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
                  <legend>
                    <label htmlFor={`${uid}-business-tax-id`}>Company Number (CRN)</label>
                  </legend>
                  <input
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
                  <legend>
                    <label htmlFor={`${uid}-business-tax-id`}>Company tax ID</label>
                  </legend>
                  <input
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
                  <legend>
                    <label htmlFor={`${uid}-business-tax-id`}>Business RFC</label>
                  </legend>
                  <input
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
                  <legend>
                    <label htmlFor={`${uid}-business-tax-id`}>Company tax ID</label>
                  </legend>
                  <input
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
          <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
            <fieldset className={cx({ danger: errorFieldNames.has("building_number") })}>
              <legend>
                <label htmlFor={`${uid}-creator-building-number`}>Block / Building Number</label>
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
            <fieldset className={cx({ danger: errorFieldNames.has("street_address_kanji") })}>
              <legend>
                <label htmlFor={`${uid}-creator-street-address-kanji`}>Street Address (Kanji)</label>
              </legend>
              <input
                id={`${uid}-creator-street-address-kanji`}
                type="text"
                placeholder="Street Address (Kanji)"
                value={complianceInfo.street_address_kanji || ""}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("street_address_kanji")}
                required
                onChange={(evt) => updateComplianceInfo({ street_address_kanji: evt.target.value })}
              />
            </fieldset>
            <fieldset className={cx({ danger: errorFieldNames.has("street_address_kana") })}>
              <legend>
                <label htmlFor={`${uid}-creator-street-address-kana`}>Street Address (Kana)</label>
              </legend>
              <input
                id={`${uid}-creator-street-address-kana`}
                type="text"
                placeholder="Street Address (Kana)"
                value={complianceInfo.street_address_kana || ""}
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("street_address_kana")}
                required
                onChange={(evt) => updateComplianceInfo({ street_address_kana: evt.target.value })}
              />
            </fieldset>
          </div>
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
      <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
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
        {complianceInfo.country === "US" ? (
          <fieldset className={cx({ danger: errorFieldNames.has("state") })}>
            <legend>
              <label htmlFor={`${uid}-creator-state`}>State</label>
            </legend>
            <select
              id={`${uid}-creator-state`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || "State"}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option disabled>State</option>
              {states.us.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </select>
          </fieldset>
        ) : complianceInfo.country === "CA" ? (
          <fieldset className={cx({ danger: errorFieldNames.has("state") })}>
            <legend>
              <label htmlFor={`${uid}-creator-province`}>Province</label>
            </legend>
            <select
              id={`${uid}-creator-province`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || "Province"}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option disabled>Province</option>
              {states.ca.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </select>
          </fieldset>
        ) : complianceInfo.country === "AU" ? (
          <fieldset className={cx({ danger: errorFieldNames.has("state") })}>
            <legend>
              <label htmlFor={`${uid}-creator-state`}>State</label>
            </legend>
            <select
              id={`${uid}-creator-state`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || "State"}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option disabled>State</option>
              {states.au.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </select>
          </fieldset>
        ) : complianceInfo.country === "MX" ? (
          <fieldset className={cx({ danger: errorFieldNames.has("state") })}>
            <legend>
              <label htmlFor={`${uid}-creator-state`}>State</label>
            </legend>
            <select
              id={`${uid}-creator-state`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || "State"}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option disabled>State</option>
              {states.mx.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </select>
          </fieldset>
        ) : complianceInfo.country === "AE" ? (
          <fieldset className={cx({ danger: errorFieldNames.has("state") })}>
            <legend>
              <label htmlFor={`${uid}-creator-province`}>Province</label>
            </legend>
            <select
              id={`${uid}-creator-province`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || "Province"}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option disabled>Province</option>
              {states.ae.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </select>
          </fieldset>
        ) : complianceInfo.country === "IE" ? (
          <fieldset className={cx({ danger: errorFieldNames.has("state") })}>
            <legend>
              <label htmlFor={`${uid}-creator-county`}>County</label>
            </legend>
            <select
              id={`${uid}-creator-county`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || "County"}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option disabled>County</option>
              {states.ir.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </select>
          </fieldset>
        ) : complianceInfo.country === "BR" ? (
          <fieldset className={cx({ danger: errorFieldNames.has("state") })}>
            <legend>
              <label htmlFor={`${uid}-creator-state`}>State</label>
            </legend>
            <select
              id={`${uid}-creator-state`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("state")}
              value={complianceInfo.state || "State"}
              onChange={(evt) => updateComplianceInfo({ state: evt.target.value })}
            >
              <option disabled>State</option>
              {states.br.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </select>
          </fieldset>
        ) : null}
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
      {user.country_code === "AE" ||
      user.country_code === "SG" ||
      user.country_code === "PK" ||
      user.country_code === "BD" ? (
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
      {(complianceInfo.is_business &&
        complianceInfo.business_country !== null &&
        user.individual_tax_id_needed_countries.includes(complianceInfo.business_country)) ||
      (complianceInfo.country !== null && user.individual_tax_id_needed_countries.includes(complianceInfo.country)) ? (
        <fieldset className={cx({ danger: errorFieldNames.has("individual_tax_id") })}>
          {complianceInfo.country === "US" ? (
            user.need_full_ssn ? (
              <div>
                <legend>
                  <label htmlFor={`${uid}-social-security-number-full`}>Social Security Number</label>
                </legend>
                <input
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
                <legend>
                  <label htmlFor={`${uid}-social-security-number`}>Last 4 digits of SSN</label>
                </legend>
                <input
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
              <legend>
                <label htmlFor={`${uid}-social-insurance-number`}>Social Insurance Number</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-colombia-id-number`}>Cédula de Ciudadanía (CC)</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-uruguay-id-number`}>Cédula de Identidad (CI)</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-hong-kong-id-number`}>Hong Kong ID Number</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-singapore-id-number`}>NRIC number / FIN</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-uae-id-number`}>Emirates ID</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-mexico-id-number`}>Personal RFC</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-kazakhstan-id-number`}>Individual identification number (IIN)</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-argentina-id-number`}>CUIL</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-peru-id-number`}>DNI number</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-snic`}>National Identity Card Number (SNIC or CNIC)</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-costa-rica-id-number`}>Tax Identification Number</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-chile-id-number`}>Rol Único Tributario (RUT)</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-dominican-republic-id-number`}>Cédula de identidad y electoral (CIE)</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-bolivia-id-number`}>Cédula de Identidad (CI)</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-paraguay-id-number`}>Cédula de Identidad (CI)</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-bangladesh-id-number`}>Personal ID number</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-mozambique-id-number`}>Mozambique Taxpayer Single ID Number (NUIT)</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-guatemala-id-number`}>Número de Identificación Tributaria (NIT)</label>
              </legend>
              <input
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
              <legend>
                <label htmlFor={`${uid}-brazil-id-number`}>Cadastro de Pessoas Físicas (CPF)</label>
              </legend>
              <input
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
        </fieldset>
      ) : null}
    </section>
  );
};
export default AccountDetailsSection;
