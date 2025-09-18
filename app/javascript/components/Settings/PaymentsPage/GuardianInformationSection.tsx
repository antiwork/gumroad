import cx from "classnames";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { NumberInput } from "$app/components/NumberInput";
import { Select } from "$app/components/Select";
import { Toggle } from "$app/components/Toggle";

interface GuardianInformationSectionProps {
  complianceInfo: {
    guardian_first_name?: string;
    guardian_last_name?: string;
    guardian_date_of_birth?: string;
    guardian_relationship?: string;
    guardian_street_address?: string;
    guardian_city?: string;
    guardian_state?: string;
    guardian_zip_code?: string;
    guardian_country?: string;
    guardian_phone?: string;
    guardian_individual_tax_id?: string;
    guardian_stripe_processing_tos_accepted?: boolean;
    guardian_stripe_tos_accepted?: boolean;
    guardian_verification_status?: string;
  };
  updateComplianceInfo: (updates: Partial<any>) => void;
  isFormDisabled: boolean;
  countries: Record<string, string>;
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
}

const GuardianInformationSection: React.FC<GuardianInformationSectionProps> = ({
  complianceInfo,
  updateComplianceInfo,
  isFormDisabled,
  countries,
  states,
  errorFieldNames,
  isVisible,
}) => {
  const uid = React.useId();

  if (!isVisible) {
    return null;
  }

  const guardianCountryCode = complianceInfo.guardian_country
    ? Object.keys(countries).find((code) => countries[code] === complianceInfo.guardian_country)
    : null;

  const availableStates = guardianCountryCode
    ? states[guardianCountryCode.toLowerCase() as keyof typeof states] || []
    : [];

  const relationshipOptions = [
    { value: "parent", label: "Parent" },
    { value: "legal_guardian", label: "Legal Guardian" },
    { value: "grandparent", label: "Grandparent" },
    { value: "sibling", label: "Sibling" },
    { value: "other", label: "Other" },
  ];

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
        <h3 className="text-gray-900 text-lg font-medium">Legal Guardian Information</h3>
        <p className="text-gray-600 mt-1 text-sm">
          Since you are under 18, we need information about your legal guardian to comply with financial regulations.
        </p>
        {complianceInfo.guardian_verification_status && (
          <div className="mt-2">
            <span className={cx("text-sm font-medium", getStatusColor(complianceInfo.guardian_verification_status))}>
              Status: {getStatusText(complianceInfo.guardian_verification_status)}
            </span>
          </div>
        )}
      </div>

      <div className="grid grid-cols-1 gap-6 sm:grid-cols-2">
        {/* Guardian Name */}
        <div>
          <label htmlFor={`${uid}-guardian-first-name`} className="text-gray-700 block text-sm font-medium">
            Guardian First Name *
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
            Guardian Last Name *
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

        {/* Guardian Date of Birth */}
        <div>
          <label className="text-gray-700 block text-sm font-medium">Guardian Date of Birth *</label>
          <div className="mt-1 grid grid-cols-3 gap-3">
            <Select
              value={
                complianceInfo.guardian_date_of_birth
                  ? new Date(complianceInfo.guardian_date_of_birth).getMonth() + 1
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
                value: (i + 1).toString(),
                label: new Date(0, i).toLocaleString("default", { month: "long" }),
              }))}
              placeholder="Month"
            />
            <NumberInput
              value={
                complianceInfo.guardian_date_of_birth ? new Date(complianceInfo.guardian_date_of_birth).getDate() : ""
              }
              onChange={(value) => {
                const currentDate = complianceInfo.guardian_date_of_birth
                  ? new Date(complianceInfo.guardian_date_of_birth)
                  : new Date();
                const newDate = new Date(currentDate.getFullYear(), currentDate.getMonth(), parseInt(value) || 1);
                updateComplianceInfo({ guardian_date_of_birth: newDate.toISOString().split("T")[0] });
              }}
              disabled={isFormDisabled}
              placeholder="Day"
              min={1}
              max={31}
            />
            <NumberInput
              value={
                complianceInfo.guardian_date_of_birth
                  ? new Date(complianceInfo.guardian_date_of_birth).getFullYear()
                  : ""
              }
              onChange={(value) => {
                const currentDate = complianceInfo.guardian_date_of_birth
                  ? new Date(complianceInfo.guardian_date_of_birth)
                  : new Date();
                const newDate = new Date(
                  parseInt(value) || new Date().getFullYear(),
                  currentDate.getMonth(),
                  currentDate.getDate(),
                );
                updateComplianceInfo({ guardian_date_of_birth: newDate.toISOString().split("T")[0] });
              }}
              disabled={isFormDisabled}
              placeholder="Year"
              min={1900}
              max={new Date().getFullYear() - 18}
            />
          </div>
        </div>

        {/* Relationship */}
        <div>
          <label htmlFor={`${uid}-guardian-relationship`} className="text-gray-700 block text-sm font-medium">
            Relationship to You *
          </label>
          <Select
            value={complianceInfo.guardian_relationship || ""}
            onChange={(value) => updateComplianceInfo({ guardian_relationship: value })}
            disabled={isFormDisabled}
            options={relationshipOptions}
            placeholder="Select relationship"
          />
        </div>

        {/* Address */}
        <div className="sm:col-span-2">
          <label htmlFor={`${uid}-guardian-street-address`} className="text-gray-700 block text-sm font-medium">
            Guardian Street Address *
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
            Guardian City *
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
            Guardian State/Province *
          </label>
          {availableStates.length > 0 ? (
            <Select
              value={complianceInfo.guardian_state || ""}
              onChange={(value) => updateComplianceInfo({ guardian_state: value })}
              disabled={isFormDisabled}
              options={availableStates.map((state) => ({
                value: state.code,
                label: state.name,
              }))}
              placeholder="Select state/province"
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
            Guardian ZIP/Postal Code *
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

        <div>
          <label htmlFor={`${uid}-guardian-country`} className="text-gray-700 block text-sm font-medium">
            Guardian Country *
          </label>
          <Select
            value={guardianCountryCode || ""}
            onChange={(value) => updateComplianceInfo({ guardian_country: countries[value] })}
            disabled={isFormDisabled}
            options={Object.entries(countries).map(([code, name]) => ({
              value: code,
              label: name,
            }))}
            placeholder="Select country"
          />
        </div>

        <div>
          <label htmlFor={`${uid}-guardian-phone`} className="text-gray-700 block text-sm font-medium">
            Guardian Phone Number *
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

        <div>
          <label htmlFor={`${uid}-guardian-tax-id`} className="text-gray-700 block text-sm font-medium">
            Guardian Tax ID/SSN *
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
            placeholder="Last 4 digits of SSN or full tax ID"
          />
        </div>
      </div>

      {/* Terms of Service */}
      <div className="border-gray-200 space-y-4 border-t pt-6">
        <h4 className="text-md text-gray-900 font-medium">Legal Guardian Consent</h4>
        <p className="text-gray-600 text-sm">
          Your legal guardian must consent to your use of Gumroad's payment processing services.
        </p>

        <div className="space-y-3">
          <div className="flex items-start">
            <div className="flex h-5 items-center">
              <Toggle
                checked={complianceInfo.guardian_stripe_processing_tos_accepted || false}
                onChange={(checked) => updateComplianceInfo({ guardian_stripe_processing_tos_accepted: checked })}
                disabled={isFormDisabled}
              />
            </div>
            <div className="ml-3 text-sm">
              <label className="text-gray-700 font-medium">Guardian agrees to Stripe's processing terms</label>
              <p className="text-gray-500">
                Your legal guardian acknowledges and agrees to Stripe's terms of service for payment processing.
              </p>
            </div>
          </div>

          <div className="flex items-start">
            <div className="flex h-5 items-center">
              <Toggle
                checked={complianceInfo.guardian_stripe_tos_accepted || false}
                onChange={(checked) => updateComplianceInfo({ guardian_stripe_tos_accepted: checked })}
                disabled={isFormDisabled}
              />
            </div>
            <div className="ml-3 text-sm">
              <label className="text-gray-700 font-medium">Guardian agrees to Stripe's terms of service</label>
              <p className="text-gray-500">Your legal guardian acknowledges and agrees to Stripe's terms of service.</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default GuardianInformationSection;
