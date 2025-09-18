import cx from "classnames";
import * as React from "react";

import { NumberInput } from "$app/components/NumberInput";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";

interface GuardianInformationSectionProps {
  complianceInfo: {
    guardian_first_name?: string | null;
    guardian_last_name?: string | null;
    guardian_email?: string | null;
    guardian_phone?: string | null;
    guardian_street_address?: string | null;
    guardian_city?: string | null;
    guardian_state?: string | null;
    guardian_zip_code?: string | null;
    guardian_date_of_birth?: string | null;
    guardian_individual_tax_id?: string | null;
    guardian_stripe_processing_tos_accepted?: boolean;
    guardian_stripe_tos_accepted?: boolean;
    guardian_verification_status?: string | null;
  };
  updateComplianceInfo: (updates: Partial<any>) => void;
  isFormDisabled: boolean;
  states: {
    us: { code: string; name: string }[];
    ca: { code: string; name: string }[];
    au: { code: string; name: string }[];
    mx: { code: string; name: string }[];
    ae: { code: string; name: string }[];
    ir: { code: string; name: string }[];
    br: { code: string; name: string }[];
  };
  errorFieldNames: Set<string>;
  isVisible: boolean;
  userCountryCode?: string | null;
}

const GuardianInformationSection: React.FC<GuardianInformationSectionProps> = ({
  complianceInfo,
  updateComplianceInfo,
  isFormDisabled,
  states,
  errorFieldNames,
  isVisible,
  userCountryCode,
}) => {
  const uid = React.useId();

  if (!isVisible) {
    return null;
  }

  // Use the user's country for guardian state validation
  const availableStates = userCountryCode ? states[userCountryCode.toLowerCase() as keyof typeof states] || [] : [];

  const getStatusColor = (status?: string) => {
    switch (status) {
      case "complete":
        return "text-green-600";
      case "pending":
        return "text-yellow-600";
      case "incomplete":
        return "text-red-600";
      default:
        return "text-gray-600";
    }
  };

  const getStatusText = (status?: string) => {
    switch (status) {
      case "complete":
        return "Verification Complete";
      case "pending":
        return "Verification Pending";
      case "incomplete":
        return "Verification Incomplete";
      default:
        return "Not Required";
    }
  };

  return (
    <div className="space-y-6">
      <div className="border-gray-200 border-b pb-4">
        <h3 className="text-gray-900 text-lg font-medium">Legal guardian's details</h3>
        <p className="text-gray-600 mt-1 text-sm">
          Because you're under 18, we need to verify your legal guardian's details to enable payments.
        </p>
        {complianceInfo.guardian_verification_status ? (
          <div className="mt-2">
            <span className={cx("text-sm font-medium", getStatusColor(complianceInfo.guardian_verification_status))}>
              Status: {getStatusText(complianceInfo.guardian_verification_status)}
            </span>
          </div>
        ) : null}
      </div>

      <div className="grid grid-cols-1 gap-6 sm:grid-cols-2">
        {/* Guardian Name */}
        <div>
          <label htmlFor={`${uid}-guardian-first-name`} className="text-gray-700 block text-sm font-medium">
            First name *
          </label>
          <input
            type="text"
            id={`${uid}-guardian-first-name`}
            value={complianceInfo.guardian_first_name || ""}
            onChange={(e) => updateComplianceInfo({ guardian_first_name: e.target.value })}
            disabled={isFormDisabled}
            className={cx(
              "border-gray-300 mt-1 block w-full rounded-md shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm",
              errorFieldNames.has("guardian_first_name") && "border-red-300 focus:border-red-500 focus:ring-red-500",
            )}
          />
        </div>

        <div>
          <label htmlFor={`${uid}-guardian-last-name`} className="text-gray-700 block text-sm font-medium">
            Last name *
          </label>
          <input
            type="text"
            id={`${uid}-guardian-last-name`}
            value={complianceInfo.guardian_last_name || ""}
            onChange={(e) => updateComplianceInfo({ guardian_last_name: e.target.value })}
            disabled={isFormDisabled}
            className={cx(
              "border-gray-300 mt-1 block w-full rounded-md shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm",
              errorFieldNames.has("guardian_last_name") && "border-red-300 focus:border-red-500 focus:ring-red-500",
            )}
          />
        </div>

        {/* Guardian Email */}
        <div>
          <label htmlFor={`${uid}-guardian-email`} className="text-gray-700 block text-sm font-medium">
            Email address *
          </label>
          <input
            type="email"
            id={`${uid}-guardian-email`}
            value={complianceInfo.guardian_email || ""}
            onChange={(e) => updateComplianceInfo({ guardian_email: e.target.value })}
            disabled={isFormDisabled}
            className={cx(
              "border-gray-300 mt-1 block w-full rounded-md shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm",
              errorFieldNames.has("guardian_email") && "border-red-300 focus:border-red-500 focus:ring-red-500",
            )}
          />
        </div>

        {/* Guardian Phone */}
        <div>
          <label htmlFor={`${uid}-guardian-phone`} className="text-gray-700 block text-sm font-medium">
            Phone number *
          </label>
          <input
            type="tel"
            id={`${uid}-guardian-phone`}
            value={complianceInfo.guardian_phone || ""}
            onChange={(e) => updateComplianceInfo({ guardian_phone: e.target.value })}
            disabled={isFormDisabled}
            className={cx(
              "border-gray-300 mt-1 block w-full rounded-md shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm",
              errorFieldNames.has("guardian_phone") && "border-red-300 focus:border-red-500 focus:ring-red-500",
            )}
          />
        </div>

        {/* Guardian Street Address */}
        <div className="sm:col-span-2">
          <label htmlFor={`${uid}-guardian-street-address`} className="text-gray-700 block text-sm font-medium">
            Street address *
          </label>
          <input
            type="text"
            id={`${uid}-guardian-street-address`}
            value={complianceInfo.guardian_street_address || ""}
            onChange={(e) => updateComplianceInfo({ guardian_street_address: e.target.value })}
            disabled={isFormDisabled}
            className={cx(
              "border-gray-300 mt-1 block w-full rounded-md shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm",
              errorFieldNames.has("guardian_street_address") &&
                "border-red-300 focus:border-red-500 focus:ring-red-500",
            )}
          />
        </div>

        <div>
          <label htmlFor={`${uid}-guardian-city`} className="text-gray-700 block text-sm font-medium">
            City *
          </label>
          <input
            type="text"
            id={`${uid}-guardian-city`}
            value={complianceInfo.guardian_city || ""}
            onChange={(e) => updateComplianceInfo({ guardian_city: e.target.value })}
            disabled={isFormDisabled}
            className={cx(
              "border-gray-300 mt-1 block w-full rounded-md shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm",
              errorFieldNames.has("guardian_city") && "border-red-300 focus:border-red-500 focus:ring-red-500",
            )}
          />
        </div>

        <div>
          <label htmlFor={`${uid}-guardian-state`} className="text-gray-700 block text-sm font-medium">
            State *
          </label>
          {availableStates.length > 0 ? (
            <TypeSafeOptionSelect
              id={`${uid}-guardian-state`}
              name="State"
              value={complianceInfo.guardian_state || ""}
              onChange={(value) => updateComplianceInfo({ guardian_state: value })}
              disabled={isFormDisabled}
              options={availableStates.map((state) => ({
                id: state.code,
                label: state.name,
              }))}
            />
          ) : (
            <input
              type="text"
              id={`${uid}-guardian-state`}
              value={complianceInfo.guardian_state || ""}
              onChange={(e) => updateComplianceInfo({ guardian_state: e.target.value })}
              disabled={isFormDisabled}
              className={cx(
                "border-gray-300 mt-1 block w-full rounded-md shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm",
                errorFieldNames.has("guardian_state") && "border-red-300 focus:border-red-500 focus:ring-red-500",
              )}
            />
          )}
        </div>

        <div>
          <label htmlFor={`${uid}-guardian-zip-code`} className="text-gray-700 block text-sm font-medium">
            Postal code *
          </label>
          <input
            type="text"
            id={`${uid}-guardian-zip-code`}
            value={complianceInfo.guardian_zip_code || ""}
            onChange={(e) => updateComplianceInfo({ guardian_zip_code: e.target.value })}
            disabled={isFormDisabled}
            className={cx(
              "border-gray-300 mt-1 block w-full rounded-md shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm",
              errorFieldNames.has("guardian_zip_code") && "border-red-300 focus:border-red-500 focus:ring-red-500",
            )}
          />
        </div>

        {/* Guardian Date of Birth */}
        <div>
          <label className="text-gray-700 block text-sm font-medium">Date of birth *</label>
          <div className="mt-1 grid grid-cols-3 gap-3">
            <TypeSafeOptionSelect
              id={`${uid}-guardian-month`}
              name="Month"
              value={
                complianceInfo.guardian_date_of_birth
                  ? (new Date(complianceInfo.guardian_date_of_birth).getMonth() + 1).toString()
                  : ""
              }
              onChange={(value) => {
                const currentDate = complianceInfo.guardian_date_of_birth
                  ? new Date(complianceInfo.guardian_date_of_birth)
                  : new Date();
                const newDate = new Date(currentDate.getFullYear(), parseInt(value) - 1, currentDate.getDate());
                updateComplianceInfo({ guardian_date_of_birth: newDate.toISOString().split("T")[0] });
              }}
              disabled={isFormDisabled}
              options={Array.from({ length: 12 }, (_, i) => ({
                id: (i + 1).toString(),
                label: new Date(0, i).toLocaleString("default", { month: "long" }),
              }))}
            />
            <NumberInput
              value={
                complianceInfo.guardian_date_of_birth ? new Date(complianceInfo.guardian_date_of_birth).getDate() : null
              }
              onChange={(value) => {
                const currentDate = complianceInfo.guardian_date_of_birth
                  ? new Date(complianceInfo.guardian_date_of_birth)
                  : new Date();
                const newDate = new Date(currentDate.getFullYear(), currentDate.getMonth(), value || 1);
                updateComplianceInfo({ guardian_date_of_birth: newDate.toISOString().split("T")[0] });
              }}
            >
              {({ onChange, value }) => (
                <input
                  type="text"
                  value={value}
                  onChange={onChange}
                  disabled={isFormDisabled}
                  placeholder="Day"
                  min={1}
                  max={31}
                  className="border-gray-300 mt-1 block w-full rounded-md shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
              )}
            </NumberInput>
            <NumberInput
              value={
                complianceInfo.guardian_date_of_birth
                  ? new Date(complianceInfo.guardian_date_of_birth).getFullYear()
                  : null
              }
              onChange={(value) => {
                const currentDate = complianceInfo.guardian_date_of_birth
                  ? new Date(complianceInfo.guardian_date_of_birth)
                  : new Date();
                const newDate = new Date(
                  value || new Date().getFullYear(),
                  currentDate.getMonth(),
                  currentDate.getDate(),
                );
                updateComplianceInfo({ guardian_date_of_birth: newDate.toISOString().split("T")[0] });
              }}
            >
              {({ onChange, value }) => (
                <input
                  type="text"
                  value={value}
                  onChange={onChange}
                  disabled={isFormDisabled}
                  placeholder="Year"
                  min={1900}
                  max={new Date().getFullYear() - 18}
                  className="border-gray-300 mt-1 block w-full rounded-md shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
              )}
            </NumberInput>
          </div>
        </div>

        {/* Guardian Tax ID */}
        <div>
          <label htmlFor={`${uid}-guardian-tax-id`} className="text-gray-700 block text-sm font-medium">
            Last 4 digits of SSN *
          </label>
          <input
            type="text"
            id={`${uid}-guardian-tax-id`}
            value={complianceInfo.guardian_individual_tax_id || ""}
            onChange={(e) => updateComplianceInfo({ guardian_individual_tax_id: e.target.value })}
            disabled={isFormDisabled}
            className={cx(
              "border-gray-300 mt-1 block w-full rounded-md shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm",
              errorFieldNames.has("guardian_individual_tax_id") &&
                "border-red-300 focus:border-red-500 focus:ring-red-500",
            )}
            placeholder="Last 4 digits of SSN"
          />
        </div>
      </div>

      {/* Terms of Service */}
      <div className="border-gray-200 space-y-4 border-t pt-6">
        <div className="space-y-3">
          <div className="flex items-start">
            <div className="flex h-5 items-center">
              <input
                type="checkbox"
                id={`${uid}-guardian-stripe-tos`}
                checked={complianceInfo.guardian_stripe_tos_accepted || false}
                onChange={(e) => updateComplianceInfo({ guardian_stripe_tos_accepted: e.target.checked })}
                disabled={isFormDisabled}
                className="border-gray-300 h-4 w-4 rounded text-indigo-600 focus:ring-indigo-500"
              />
            </div>
            <div className="ml-3 text-sm">
              <label htmlFor={`${uid}-guardian-stripe-tos`} className="text-gray-700">
                I accept the Stripe Terms of Service as the legal guardian of the account holder.
              </label>
            </div>
          </div>

          <div className="flex items-start">
            <div className="flex h-5 items-center">
              <input
                type="checkbox"
                id={`${uid}-guardian-consent`}
                checked={complianceInfo.guardian_stripe_processing_tos_accepted || false}
                onChange={(e) => updateComplianceInfo({ guardian_stripe_processing_tos_accepted: e.target.checked })}
                disabled={isFormDisabled}
                className="border-gray-300 h-4 w-4 rounded text-indigo-600 focus:ring-indigo-500"
              />
            </div>
            <div className="ml-3 text-sm">
              <label htmlFor={`${uid}-guardian-consent`} className="text-gray-700">
                I acknowledge that I am the legal guardian of the account holder and consent to the collection and
                processing of my information for verification purposes.
              </label>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default GuardianInformationSection;
