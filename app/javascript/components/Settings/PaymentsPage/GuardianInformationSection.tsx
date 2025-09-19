import cx from "classnames";
import * as React from "react";

import { ComplianceInfo, FormFieldName } from "$app/components/server-components/Settings/PaymentsPage";

const GuardianInformationSection = ({
  complianceInfo,
  updateComplianceInfo,
  isFormDisabled,
  errorFieldNames,
  isVisible,
  user,
}: {
  complianceInfo: ComplianceInfo;
  updateComplianceInfo: (newComplianceInfo: Partial<ComplianceInfo>) => void;
  isFormDisabled: boolean;
  errorFieldNames: Set<FormFieldName>;
  isVisible: boolean;
  user: any;
}) => {
  const uid = React.useId();

  if (!isVisible) {
    return null;
  }

  const currentYear = new Date().getFullYear();

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
            onChange={(e) => updateComplianceInfo({ guardian_phone: e.target.value })}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_phone")}
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
          />
        </fieldset>

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
        <fieldset className={cx({ danger: errorFieldNames.has("guardian_individual_tax_id") })}>
          <legend>
            <label htmlFor={`${uid}-guardian-ssn`}>
              {complianceInfo.country === "US" ? "Last 4 digits of SSN" : "Last 4 digits of SIN"}
            </label>
          </legend>
          <input
            id={`${uid}-guardian-ssn`}
            type="text"
            placeholder="****"
            maxLength={4}
            value={complianceInfo.guardian_individual_tax_id || ""}
            onChange={(e) => updateComplianceInfo({ guardian_individual_tax_id: e.target.value })}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("guardian_individual_tax_id")}
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
