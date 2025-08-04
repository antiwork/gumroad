import cx from "classnames";
import { CountryCode, parsePhoneNumber } from "libphonenumber-js";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { ComplianceInfo, FormFieldName, User } from "$app/components/server-components/Settings/PaymentsPage";

const LegalGuardianDetailsSections = ({
  user,
  complianceInfo,
  updateComplianceInfo,
  isFormDisabled,
  countries,
  states,
  errorFieldNames,
}: {
  user: User;
  complianceInfo: ComplianceInfo;
  updateComplianceInfo: (newComplianceInfo: Partial<ComplianceInfo>) => void;
  isFormDisabled: boolean;
  countries: Record<string, string>;
  states: {
    us: { code: string; name: string }[];
    ca: { code: string; name: string }[];
    au: { code: string; name: string }[];
  };
  errorFieldNames: Set<FormFieldName>;
}) => {
  const uid = React.useId();

  const formatPhoneNumber = (phoneNumber: string, country_code: string | null) => {
    try {
      const countryCode: CountryCode = cast(country_code);
      return parsePhoneNumber(phoneNumber, countryCode).format("E.164");
    } catch {
      return phoneNumber;
    }
  };

  return (
    <section id="legal-guardian-section" style={{ display: "grid", gap: "var(--spacer-6)" }}>
      <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
        <fieldset className={cx({ danger: errorFieldNames.has("guardian_first_name") })}>
          <legend>
            <label htmlFor={`${uid}-guardian-first-name`}>First name</label>
          </legend>
          <input
            id={`${uid}-guardian-first-name`}
            type="text"
            placeholder="First name"
            value={complianceInfo.guardian_first_name || ""}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_first_name")}
            required
            onChange={(evt) => updateComplianceInfo({ guardian_first_name: evt.target.value })}
          />
        </fieldset>
        <fieldset className={cx({ danger: errorFieldNames.has("guardian_last_name") })}>
          <legend>
            <label htmlFor={`${uid}-guardian-last-name`}>Last name</label>
          </legend>
          <input
            id={`${uid}-guardian-last-name`}
            type="text"
            placeholder="Last name"
            value={complianceInfo.guardian_last_name || ""}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_last_name")}
            required
            onChange={(evt) => updateComplianceInfo({ guardian_last_name: evt.target.value })}
          />
        </fieldset>
      </div>

      <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
        <fieldset className={cx({ danger: errorFieldNames.has("guardian_email") })}>
          <legend>
            <label htmlFor={`${uid}-guardian-email`}>Email address</label>
          </legend>
          <input
            id={`${uid}-guardian-email`}
            type="email"
            placeholder="guardian@example.com"
            value={complianceInfo.guardian_email || ""}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_email")}
            required
            onChange={(evt) => updateComplianceInfo({ guardian_email: evt.target.value })}
          />
        </fieldset>
        <fieldset className={cx({ danger: errorFieldNames.has("guardian_phone") })}>
          <legend>
            <label htmlFor={`${uid}-guardian-phone`}>Phone number</label>
          </legend>
          <input
            id={`${uid}-guardian-phone`}
            type="tel"
            placeholder="Phone number"
            value={complianceInfo.guardian_phone || ""}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_phone")}
            required
            onChange={(evt) =>
              updateComplianceInfo({
                guardian_phone: formatPhoneNumber(
                  evt.target.value,
                  complianceInfo.guardian_country || complianceInfo.country,
                ),
              })
            }
          />
        </fieldset>
      </div>

      <fieldset className={cx({ danger: errorFieldNames.has("guardian_street_address") })}>
        <legend>
          <label htmlFor={`${uid}-guardian-street-address`}>Address</label>
        </legend>
        <input
          id={`${uid}-guardian-street-address`}
          type="text"
          placeholder="Street address"
          required
          value={complianceInfo.guardian_street_address || ""}
          disabled={isFormDisabled}
          aria-invalid={errorFieldNames.has("guardian_street_address")}
          onChange={(evt) => updateComplianceInfo({ guardian_street_address: evt.target.value })}
        />
      </fieldset>

      <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
        <fieldset className={cx({ danger: errorFieldNames.has("guardian_city") })}>
          <legend>
            <label htmlFor={`${uid}-guardian-city`}>City</label>
          </legend>
          <input
            id={`${uid}-guardian-city`}
            type="text"
            placeholder="City"
            value={complianceInfo.guardian_city || ""}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_city")}
            required
            onChange={(evt) => updateComplianceInfo({ guardian_city: evt.target.value })}
          />
        </fieldset>
        {(complianceInfo.guardian_country || complianceInfo.country) === "US" ? (
          <fieldset className={cx({ danger: errorFieldNames.has("guardian_state") })}>
            <legend>
              <label htmlFor={`${uid}-guardian-state`}>State</label>
            </legend>
            <select
              id={`${uid}-guardian-state`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("guardian_state")}
              value={complianceInfo.guardian_state || "State"}
              onChange={(evt) => updateComplianceInfo({ guardian_state: evt.target.value })}
            >
              <option disabled>State</option>
              {states.us.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </select>
          </fieldset>
        ) : (complianceInfo.guardian_country || complianceInfo.country) === "CA" ? (
          <fieldset className={cx({ danger: errorFieldNames.has("guardian_state") })}>
            <legend>
              <label htmlFor={`${uid}-guardian-province`}>Province</label>
            </legend>
            <select
              id={`${uid}-guardian-province`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("guardian_state")}
              value={complianceInfo.guardian_state || "Province"}
              onChange={(evt) => updateComplianceInfo({ guardian_state: evt.target.value })}
            >
              <option disabled>Province</option>
              {states.ca.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </select>
          </fieldset>
        ) : (complianceInfo.guardian_country || complianceInfo.country) === "AU" ? (
          <fieldset className={cx({ danger: errorFieldNames.has("guardian_state") })}>
            <legend>
              <label htmlFor={`${uid}-guardian-state`}>State</label>
            </legend>
            <select
              id={`${uid}-guardian-state`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("guardian_state")}
              value={complianceInfo.guardian_state || "State"}
              onChange={(evt) => updateComplianceInfo({ guardian_state: evt.target.value })}
            >
              <option disabled>State</option>
              {states.au.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </select>
          </fieldset>
        ) : null}
        <fieldset className={cx({ danger: errorFieldNames.has("guardian_zip_code") })}>
          <legend>
            <label htmlFor={`${uid}-guardian-zip-code`}>
              {(complianceInfo.guardian_country || complianceInfo.country) === "US" ? "ZIP code" : "Postal code"}
            </label>
          </legend>
          <input
            id={`${uid}-guardian-zip-code`}
            type="text"
            placeholder={
              (complianceInfo.guardian_country || complianceInfo.country) === "US" ? "ZIP code" : "Postal code"
            }
            value={complianceInfo.guardian_zip_code || ""}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_zip_code")}
            required
            onChange={(evt) => updateComplianceInfo({ guardian_zip_code: evt.target.value })}
          />
        </fieldset>
      </div>

      <fieldset>
        <legend>
          <label htmlFor={`${uid}-guardian-country`}>Country</label>
        </legend>
        <select
          id={`${uid}-guardian-country`}
          disabled={isFormDisabled}
          value={complianceInfo.guardian_country || complianceInfo.country || ""}
          onChange={(evt) => updateComplianceInfo({ guardian_country: evt.target.value })}
        >
          {Object.entries(countries).map(([code, name]) => (
            <option key={code} value={code}>
              {name}
            </option>
          ))}
        </select>
      </fieldset>

      <fieldset>
        <legend>
          <label>Date of birth</label>
        </legend>
        <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
          <fieldset className={cx({ danger: errorFieldNames.has("guardian_dob_month") })}>
            <select
              id={`${uid}-guardian-dob-month`}
              disabled={isFormDisabled}
              required
              aria-label="Month"
              aria-invalid={errorFieldNames.has("guardian_dob_month")}
              value={complianceInfo.guardian_dob_month || "Month"}
              onChange={(evt) => updateComplianceInfo({ guardian_dob_month: Number(evt.target.value) })}
            >
              <option disabled>Month</option>
              {Array.from({ length: 12 }, (_, i) => i + 1).map((month) => (
                <option key={month} value={month}>
                  {month}
                </option>
              ))}
            </select>
          </fieldset>
          <fieldset className={cx({ danger: errorFieldNames.has("guardian_dob_day") })}>
            <select
              id={`${uid}-guardian-dob-day`}
              disabled={isFormDisabled}
              required
              aria-label="Day"
              aria-invalid={errorFieldNames.has("guardian_dob_day")}
              value={complianceInfo.guardian_dob_day || "Day"}
              onChange={(evt) => updateComplianceInfo({ guardian_dob_day: Number(evt.target.value) })}
            >
              <option disabled>Day</option>
              {Array.from({ length: 31 }, (_, i) => i + 1).map((day) => (
                <option key={day} value={day}>
                  {day}
                </option>
              ))}
            </select>
          </fieldset>
          <fieldset className={cx({ danger: errorFieldNames.has("guardian_dob_year") })}>
            <select
              id={`${uid}-guardian-dob-year`}
              disabled={isFormDisabled}
              required
              aria-label="Year"
              aria-invalid={errorFieldNames.has("guardian_dob_year")}
              value={complianceInfo.guardian_dob_year || "Year"}
              onChange={(evt) => updateComplianceInfo({ guardian_dob_year: Number(evt.target.value) })}
            >
              <option disabled>Year</option>
              {Array.from({ length: 80 }, (_, i) => new Date().getFullYear() - 18 - i).map((year) => (
                <option key={year} value={year}>
                  {year}
                </option>
              ))}
            </select>
          </fieldset>
        </div>
      </fieldset>
      {(complianceInfo.guardian_country || complianceInfo.country) !== null &&
      user.individual_tax_id_needed_countries.includes(
        complianceInfo.guardian_country || complianceInfo.country || "",
      ) ? (
        <fieldset className={cx({ danger: errorFieldNames.has("guardian_individual_tax_id") })}>
          {(complianceInfo.guardian_country || complianceInfo.country) === "US" ? (
            user.need_full_ssn ? (
              <div>
                <legend>
                  <label htmlFor={`${uid}-guardian-social-security-number-full`}>Social Security Number</label>
                </legend>
                <input
                  id={`${uid}-guardian-social-security-number-full`}
                  type="text"
                  minLength={9}
                  maxLength={11}
                  placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "•••-••-••••"}
                  required
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                  onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
                />
              </div>
            ) : (
              <div>
                <legend>
                  <label htmlFor={`${uid}-guardian-social-security-number`}>Last 4 digits of SSN</label>
                </legend>
                <input
                  id={`${uid}-guardian-social-security-number`}
                  type="text"
                  minLength={4}
                  maxLength={4}
                  placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "••••"}
                  required
                  disabled={isFormDisabled}
                  aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                  onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
                />
              </div>
            )
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "CA" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-social-insurance-number`}>Social Insurance Number</label>
              </legend>
              <input
                id={`${uid}-guardian-social-insurance-number`}
                type="text"
                minLength={9}
                maxLength={9}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "•••••••••"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "CO" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-colombia-id-number`}>Cédula de Ciudadanía (CC)</label>
              </legend>
              <input
                id={`${uid}-guardian-colombia-id-number`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "1.123.123.123"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "UY" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-uruguay-id-number`}>Cédula de Identidad (CI)</label>
              </legend>
              <input
                id={`${uid}-guardian-uruguay-id-number`}
                type="text"
                minLength={11}
                maxLength={11}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "1.123.123-1"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "HK" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-hong-kong-id-number`}>Hong Kong ID Number</label>
              </legend>
              <input
                id={`${uid}-guardian-hong-kong-id-number`}
                type="text"
                minLength={8}
                maxLength={9}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "SG" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-singapore-id-number`}>NRIC number / FIN</label>
              </legend>
              <input
                id={`${uid}-guardian-singapore-id-number`}
                type="text"
                minLength={9}
                maxLength={9}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "AE" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-uae-id-number`}>Emirates ID</label>
              </legend>
              <input
                id={`${uid}-guardian-uae-id-number`}
                type="text"
                minLength={15}
                maxLength={15}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "123456789123456"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "MX" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-mexico-id-number`}>Personal RFC</label>
              </legend>
              <input
                id={`${uid}-guardian-mexico-id-number`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "1234567891234"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "KZ" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-kazakhstan-id-number`}>Individual identification number (IIN)</label>
              </legend>
              <input
                id={`${uid}-guardian-kazakhstan-id-number`}
                type="text"
                minLength={9}
                maxLength={12}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "AR" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-argentina-id-number`}>CUIL</label>
              </legend>
              <input
                id={`${uid}-guardian-argentina-id-number`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "12-12345678-1"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "PE" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-peru-id-number`}>DNI number</label>
              </legend>
              <input
                id={`${uid}-guardian-peru-id-number`}
                type="text"
                minLength={10}
                maxLength={10}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "12345678-9"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "PK" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-snic`}>National Identity Card Number (SNIC or CNIC)</label>
              </legend>
              <input
                id={`${uid}-guardian-snic`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "•••••••••"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "CR" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-costa-rica-id-number`}>Tax Identification Number</label>
              </legend>
              <input
                id={`${uid}-guardian-costa-rica-id-number`}
                type="text"
                minLength={9}
                maxLength={12}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "1234567890"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "CL" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-chile-id-number`}>Rol Único Tributario (RUT)</label>
              </legend>
              <input
                id={`${uid}-guardian-chile-id-number`}
                type="text"
                minLength={8}
                maxLength={9}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "DO" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-dominican-republic-id-number`}>
                  Cédula de identidad y electoral (CIE)
                </label>
              </legend>
              <input
                id={`${uid}-guardian-dominican-republic-id-number`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "123-1234567-1"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "BO" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-bolivia-id-number`}>Cédula de Identidad (CI)</label>
              </legend>
              <input
                id={`${uid}-guardian-bolivia-id-number`}
                type="text"
                minLength={8}
                maxLength={8}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "12345678"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "PY" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-paraguay-id-number`}>Cédula de Identidad (CI)</label>
              </legend>
              <input
                id={`${uid}-guardian-paraguay-id-number`}
                type="text"
                minLength={7}
                maxLength={7}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "1234567"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "BD" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-bangladesh-id-number`}>Personal ID number</label>
              </legend>
              <input
                id={`${uid}-guardian-bangladesh-id-number`}
                type="text"
                minLength={1}
                maxLength={20}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "MZ" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-mozambique-id-number`}>
                  Mozambique Taxpayer Single ID Number (NUIT)
                </label>
              </legend>
              <input
                id={`${uid}-guardian-mozambique-id-number`}
                type="text"
                minLength={9}
                maxLength={9}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "GT" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-guatemala-id-number`}>Número de Identificación Tributaria (NIT)</label>
              </legend>
              <input
                id={`${uid}-guardian-guatemala-id-number`}
                type="text"
                minLength={8}
                maxLength={12}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "1234567-8"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : (complianceInfo.guardian_country || complianceInfo.country) === "BR" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-brazil-id-number`}>Cadastro de Pessoas Físicas (CPF)</label>
              </legend>
              <input
                id={`${uid}-guardian-brazil-id-number`}
                type="text"
                minLength={11}
                maxLength={14}
                placeholder={user.guardian_individual_tax_id_entered ? "Hidden for security" : "123.456.789-00"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
                onChange={(evt) => updateComplianceInfo({ guardian_individual_tax_id: evt.target.value })}
              />
            </div>
          ) : null}
        </fieldset>
      ) : null}
      <div style={{ display: "grid", gap: "var(--spacer-4)" }}>
        <h3
          style={{
            fontSize: "var(--font-size-lg)",
            fontWeight: "var(--font-weight-semibold)",
            borderBottom: "1px solid var(--color-border)",
            paddingBottom: "var(--spacer-2)",
          }}
        >
          Terms of Service
        </h3>
        <div style={{ display: "grid", gap: "var(--spacer-3)" }}>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-guardian-tos-accepted`}>
                <input
                  id={`${uid}-guardian-tos-accepted`}
                  type="checkbox"
                  checked={complianceInfo.guardian_stripe_tos_accepted ?? false}
                  disabled={isFormDisabled || (complianceInfo.guardian_stripe_tos_accepted ?? false)}
                  required
                  onChange={(e) => updateComplianceInfo({ guardian_stripe_tos_accepted: e.target.checked })}
                />
                I accept the{" "}
                <a
                  href="https://stripe.com/legal/ssa"
                  style={{ color: "var(--color-link)", textDecoration: "underline" }}
                >
                  Stripe Terms of Service
                </a>{" "}
                as the legal guardian of the account holder.
              </label>
            </legend>
          </fieldset>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-guardian-additional-tos-accepted`}>
                <input
                  id={`${uid}-guardian-additional-tos-accepted`}
                  type="checkbox"
                  checked={complianceInfo.guardian_stripe_processing_tos_accepted ?? false}
                  disabled={isFormDisabled || (complianceInfo.guardian_stripe_processing_tos_accepted ?? false)}
                  required
                  onChange={(e) => updateComplianceInfo({ guardian_stripe_processing_tos_accepted: e.target.checked })}
                />
                I acknowledge that I am the legal guardian of the account holder and consent to the collection and
                processing of my information for verification purposes.
              </label>
            </legend>
          </fieldset>
        </div>
      </div>
    </section>
  );
};
export default LegalGuardianDetailsSections;
