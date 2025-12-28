import * as React from "react";

import { Icon } from "$app/components/Icons";
import { ToggleSettingRow } from "$app/components/SettingRow";

import { AvailableOfferCode, DefaultOfferCode } from "../state";

const selectOfferCode = (offerCode: AvailableOfferCode): DefaultOfferCode => ({
  id: offerCode.id,
  name: offerCode.name,
  code: offerCode.code,
  discount: offerCode.discount,
});

export const ApplyDiscountEditor = ({
  availableOfferCodes,
  defaultOfferCode,
  onDefaultOfferCodeChange,
}: {
  availableOfferCodes: AvailableOfferCode[];
  defaultOfferCode: DefaultOfferCode | null;
  onDefaultOfferCodeChange: (value: DefaultOfferCode | null) => void;
}) => {
  if (availableOfferCodes.length === 0) {
    return null;
  }

  const selectedOfferCode = availableOfferCodes.find((oc) => oc.id === defaultOfferCode?.id);

  const handleToggleChange = (enabled: boolean) => {
    const firstOfferCode = availableOfferCodes[0];
    onDefaultOfferCodeChange(enabled && firstOfferCode ? selectOfferCode(firstOfferCode) : null);
  };

  const handleOfferCodeChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    const selected = availableOfferCodes.find((oc) => oc.id === e.target.value);
    onDefaultOfferCodeChange(selected ? selectOfferCode(selected) : null);
  };

  return (
    <ToggleSettingRow
      value={!!selectedOfferCode}
      onChange={handleToggleChange}
      label="Apply discount"
      dropdown={
        <fieldset>
          <label htmlFor="apply-discount-code">Discount code</label>
          <div style={{ position: "relative" }}>
            <select
              id="apply-discount-code"
              value={selectedOfferCode?.id ?? ""}
              onChange={handleOfferCodeChange}
              style={selectedOfferCode ? { paddingRight: "var(--spacer-12)" } : undefined}
            >
              <option value="">Select a discount code</option>
              {availableOfferCodes.map((oc) => (
                <option key={oc.id} value={oc.id}>
                  {oc.name}
                </option>
              ))}
            </select>
            {selectedOfferCode ? (
              <button
                type="button"
                onClick={() => onDefaultOfferCodeChange(null)}
                aria-label="Clear discount code"
                style={{
                  position: "absolute",
                  right: "var(--spacer-7)",
                  top: "50%",
                  transform: "translateY(-50%)",
                  background: "none",
                  border: "none",
                  padding: 0,
                  cursor: "pointer",
                  display: "flex",
                  alignItems: "center",
                }}
              >
                <Icon name="x" className="text-sm" />
              </button>
            ) : null}
          </div>
        </fieldset>
      }
    />
  );
};
