import cx from "classnames";
import { CountryCode, parsePhoneNumber } from "libphonenumber-js";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { ComplianceInfo, FormFieldName, User } from "$app/components/server-components/Settings/PaymentsPage";

import StateSelector, { getStateLabel } from "./StateSelector";
import TaxIdInput from "./TaxIdInput";

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

        {complianceInfo.country ? (
          <fieldset className={cx({ danger: errorFieldNames.has("guardian_state") })}>
            <legend>
              <label htmlFor={`${uid}-guardian-state`}>{getStateLabel(complianceInfo.country)}</label>
            </legend>
            <StateSelector
              country={complianceInfo.country}
              uid={`${uid}-guardian`}
              value={complianceInfo.guardian_state || null}
              isFormDisabled={isFormDisabled}
              hasError={errorFieldNames.has("guardian_state")}
              onChange={(value) => updateComplianceInfo({ guardian_state: value })}
              required
              states={states}
            />
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
          <TaxIdInput
            country={complianceInfo.country}
            uid={uid}
            value={complianceInfo.guardian_tax_id || null}
            isEntered={!!complianceInfo.guardian_tax_id}
            isFormDisabled={isFormDisabled}
            hasError={errorFieldNames.has("guardian_tax_id")}
            onChange={(value) => updateComplianceInfo({ guardian_tax_id: value })}
            required
          />
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
