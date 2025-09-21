import cx from "classnames";
import { CountryCode, parsePhoneNumber } from "libphonenumber-js";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { ComplianceInfo, FormFieldName, User } from "$app/components/server-components/Settings/PaymentsPage";

const GuardianInformationSection = ({
  complianceInfo,
  updateComplianceInfo,
  isFormDisabled,
  errorFieldNames,
  isVisible,
  user,
  states,
}: {
  complianceInfo: ComplianceInfo;
  updateComplianceInfo: (newComplianceInfo: Partial<ComplianceInfo>) => void;
  isFormDisabled: boolean;
  errorFieldNames: Set<FormFieldName>;
  isVisible: boolean;
  user: User;
  states: {
    us: { code: string; name: string }[];
    ca: { code: string; name: string }[];
    au: { code: string; name: string }[];
    mx: { code: string; name: string }[];
    ae: { code: string; name: string }[];
    ir: { code: string; name: string }[];
    br: { code: string; name: string }[];
  };
}) => {
  const uid = React.useId();

  if (!isVisible) {
    return null;
  }

  const currentYear = new Date().getFullYear();

  const formatPhoneNumber = (phoneNumber: string, country_code: string | null) => {
    try {
      const countryCode: CountryCode = cast(country_code);
      return parsePhoneNumber(phoneNumber, countryCode).format("E.164");
    } catch {
      return phoneNumber;
    }
  };

  return (
    <section style={{ display: "grid", gap: "var(--spacer-6)" }}>
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
            onChange={(e) => updateComplianceInfo({ guardian_first_name: e.target.value })}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_first_name")}
            required
          />
          <small>Include middle name if it appears on ID.</small>
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
            onChange={(e) => updateComplianceInfo({ guardian_last_name: e.target.value })}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_last_name")}
            required
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
            placeholder="Email address"
            value={complianceInfo.guardian_email || ""}
            onChange={(e) => updateComplianceInfo({ guardian_email: e.target.value })}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_email")}
            required
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
            onChange={(e) =>
              updateComplianceInfo({
                guardian_phone: formatPhoneNumber(e.target.value, complianceInfo.country),
              })
            }
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_phone")}
            required
          />
        </fieldset>
      </div>

      <fieldset className={cx({ danger: errorFieldNames.has("guardian_street_address") })}>
        <legend>
          <label htmlFor={`${uid}-guardian-address`}>Address</label>
        </legend>
        <input
          id={`${uid}-guardian-address`}
          type="text"
          placeholder="Street address"
          value={complianceInfo.guardian_street_address || ""}
          onChange={(e) => updateComplianceInfo({ guardian_street_address: e.target.value })}
          disabled={isFormDisabled}
          aria-invalid={errorFieldNames.has("guardian_street_address")}
          required
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
            onChange={(e) => updateComplianceInfo({ guardian_city: e.target.value })}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_city")}
            required
          />
        </fieldset>

        {complianceInfo.country === "US" ? (
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
        ) : complianceInfo.country === "CA" ? (
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
        ) : complianceInfo.country === "AU" ? (
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
        ) : complianceInfo.country === "MX" ? (
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
              {states.mx.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </select>
          </fieldset>
        ) : complianceInfo.country === "AE" ? (
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
              {states.ae.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </select>
          </fieldset>
        ) : complianceInfo.country === "IE" ? (
          <fieldset className={cx({ danger: errorFieldNames.has("guardian_state") })}>
            <legend>
              <label htmlFor={`${uid}-guardian-county`}>County</label>
            </legend>
            <select
              id={`${uid}-guardian-county`}
              required
              disabled={isFormDisabled}
              aria-invalid={errorFieldNames.has("guardian_state")}
              value={complianceInfo.guardian_state || "County"}
              onChange={(evt) => updateComplianceInfo({ guardian_state: evt.target.value })}
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
              {states.br.map((state) => (
                <option key={state.code} value={state.code}>
                  {state.name}
                </option>
              ))}
            </select>
          </fieldset>
        ) : null}

        <fieldset className={cx({ danger: errorFieldNames.has("guardian_zip_code") })}>
          <legend>
            <label htmlFor={`${uid}-guardian-zip`}>Postal code</label>
          </legend>
          <input
            id={`${uid}-guardian-zip`}
            type="text"
            placeholder="Postal code"
            value={complianceInfo.guardian_zip_code || ""}
            onChange={(e) => updateComplianceInfo({ guardian_zip_code: e.target.value })}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_zip_code")}
            required
          />
        </fieldset>
      </div>

      <fieldset>
        <legend>
          <label>Date of Birth</label>
        </legend>
        <div style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}>
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
              {Array.from({ length: 100 }, (_, i) => currentYear - i).map((year) => (
                <option key={year} value={year}>
                  {year}
                </option>
              ))}
            </select>
          </fieldset>
        </div>
      </fieldset>

      {complianceInfo.country !== null && user.individual_tax_id_needed_countries.includes(complianceInfo.country) ? (
        <fieldset className={cx({ danger: errorFieldNames.has("guardian_tax_id") })}>
          {complianceInfo.country === "US" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-social-security-number`}>Last 4 digits of SSN</label>
              </legend>
              <input
                id={`${uid}-guardian-social-security-number`}
                type="text"
                minLength={4}
                maxLength={4}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "••••"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "CA" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-social-insurance-number`}>Social Insurance Number</label>
              </legend>
              <input
                id={`${uid}-guardian-social-insurance-number`}
                type="text"
                minLength={9}
                maxLength={9}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "•••••••••"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "CO" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-colombia-id-number`}>Cédula de Ciudadanía (CC)</label>
              </legend>
              <input
                id={`${uid}-guardian-colombia-id-number`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "1.123.123.123"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "UY" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-uruguay-id-number`}>Cédula de Identidad (CI)</label>
              </legend>
              <input
                id={`${uid}-guardian-uruguay-id-number`}
                type="text"
                minLength={11}
                maxLength={11}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "1.123.123-1"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "HK" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-hong-kong-id-number`}>Hong Kong ID Number</label>
              </legend>
              <input
                id={`${uid}-guardian-hong-kong-id-number`}
                type="text"
                minLength={8}
                maxLength={9}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "SG" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-singapore-id-number`}>NRIC number / FIN</label>
              </legend>
              <input
                id={`${uid}-guardian-singapore-id-number`}
                type="text"
                minLength={9}
                maxLength={9}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "AE" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-uae-id-number`}>Emirates ID</label>
              </legend>
              <input
                id={`${uid}-guardian-uae-id-number`}
                type="text"
                minLength={15}
                maxLength={15}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "123456789123456"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "MX" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-mexico-id-number`}>Personal RFC</label>
              </legend>
              <input
                id={`${uid}-guardian-mexico-id-number`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "1234567891234"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "KZ" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-kazakhstan-id-number`}>Individual identification number (IIN)</label>
              </legend>
              <input
                id={`${uid}-guardian-kazakhstan-id-number`}
                type="text"
                minLength={9}
                maxLength={12}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "AR" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-argentina-id-number`}>CUIL</label>
              </legend>
              <input
                id={`${uid}-guardian-argentina-id-number`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "12-12345678-1"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "PE" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-peru-id-number`}>DNI number</label>
              </legend>
              <input
                id={`${uid}-guardian-peru-id-number`}
                type="text"
                minLength={10}
                maxLength={10}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "12345678-9"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "PK" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-snic`}>National Identity Card Number (SNIC or CNIC)</label>
              </legend>
              <input
                id={`${uid}-guardian-snic`}
                type="text"
                minLength={13}
                maxLength={13}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "•••••••••"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "CR" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-costa-rica-id-number`}>Tax Identification Number</label>
              </legend>
              <input
                id={`${uid}-guardian-costa-rica-id-number`}
                type="text"
                minLength={9}
                maxLength={12}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "1234567890"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "CL" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-chile-id-number`}>Rol Único Tributario (RUT)</label>
              </legend>
              <input
                id={`${uid}-guardian-chile-id-number`}
                type="text"
                minLength={8}
                maxLength={9}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "DO" ? (
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
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "123-1234567-1"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "BO" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-bolivia-id-number`}>Cédula de Identidad (CI)</label>
              </legend>
              <input
                id={`${uid}-guardian-bolivia-id-number`}
                type="text"
                minLength={8}
                maxLength={8}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "12345678"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "PY" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-paraguay-id-number`}>Cédula de Identidad (CI)</label>
              </legend>
              <input
                id={`${uid}-guardian-paraguay-id-number`}
                type="text"
                minLength={7}
                maxLength={7}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "1234567"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "BD" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-bangladesh-id-number`}>Personal ID number</label>
              </legend>
              <input
                id={`${uid}-guardian-bangladesh-id-number`}
                type="text"
                minLength={1}
                maxLength={20}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "MZ" ? (
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
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "123456789"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "GT" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-guatemala-id-number`}>Número de Identificación Tributaria (NIT)</label>
              </legend>
              <input
                id={`${uid}-guardian-guatemala-id-number`}
                type="text"
                minLength={8}
                maxLength={12}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "1234567-8"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : complianceInfo.country === "BR" ? (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-brazil-id-number`}>Cadastro de Pessoas Físicas (CPF)</label>
              </legend>
              <input
                id={`${uid}-guardian-brazil-id-number`}
                type="text"
                minLength={11}
                maxLength={14}
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "123.456.789-00"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          ) : (
            <div>
              <legend>
                <label htmlFor={`${uid}-guardian-tax-id`}>Tax ID</label>
              </legend>
              <input
                id={`${uid}-guardian-tax-id`}
                type="text"
                placeholder={complianceInfo.guardian_tax_id ? "Hidden for security" : "•••••••••"}
                required
                disabled={isFormDisabled}
                aria-invalid={errorFieldNames.has("guardian_tax_id")}
                onChange={(e) => updateComplianceInfo({ guardian_tax_id: e.target.value })}
              />
            </div>
          )}
        </fieldset>
      ) : null}

      <fieldset>
        <legend>
          <label htmlFor={`${uid}-guardian-stripe-tos`}>
            <input
              id={`${uid}-guardian-stripe-tos`}
              type="checkbox"
              checked={complianceInfo.guardian_stripe_tos_accepted || false}
              onChange={(e) => updateComplianceInfo({ guardian_stripe_tos_accepted: e.target.checked })}
              disabled={isFormDisabled}
            />
            I accept the{" "}
            <a href="https://stripe.com/legal" target="_blank" rel="noreferrer">
              Stripe Terms of Service
            </a>{" "}
            as the legal guardian of the account holder.
          </label>
        </legend>
      </fieldset>

      <fieldset>
        <legend>
          <label htmlFor={`${uid}-guardian-consent`}>
            <input
              id={`${uid}-guardian-consent`}
              type="checkbox"
              checked={complianceInfo.guardian_stripe_processing_tos_accepted || false}
              onChange={(e) => updateComplianceInfo({ guardian_stripe_processing_tos_accepted: e.target.checked })}
              disabled={isFormDisabled}
            />
            I acknowledge that I am the legal guardian of the account holder and consent to the collection and
            processing of my information for verification purposes.
          </label>
        </legend>
      </fieldset>
    </section>
  );
};

export default GuardianInformationSection;
