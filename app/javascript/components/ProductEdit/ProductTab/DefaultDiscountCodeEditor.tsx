import * as React from "react";

import { getAllProductOfferCodes, SimpleOfferCode } from "$app/data/offer_code";
import { assertResponseError } from "$app/utils/request";

import { Select, Option } from "$app/components/Select";
import { ToggleSettingRow } from "$app/components/SettingRow";

export const DefaultDiscountCodeEditor = ({
  defaultDiscountCode,
  onDefaultDiscountCodeChange,
  productId,
}: {
  defaultDiscountCode: string | null;
  onDefaultDiscountCodeChange: (value: string | null) => void;
  productId?: string | undefined;
}) => {
  const [enabled, setEnabled] = React.useState(!!defaultDiscountCode);
  const [offerCodes, setOfferCodes] = React.useState<SimpleOfferCode[]>([]);
  const [isLoading, setIsLoading] = React.useState(false);
  const [selectedCode, setSelectedCode] = React.useState<Option | null>(null);

  React.useEffect(() => {
    if (productId) {
      setIsLoading(true);
      getAllProductOfferCodes(productId)
        .then((codes) => {
          setOfferCodes(codes);
          if (defaultDiscountCode) {
            const matchingCode = codes.find((c) => c.code === defaultDiscountCode);
            if (matchingCode) {
              setSelectedCode({ id: matchingCode.code, label: matchingCode.name });
            } else {
              setSelectedCode({ id: defaultDiscountCode, label: defaultDiscountCode });
            }
          }
        })
        .catch((err: unknown) => {
          assertResponseError(err);
          console.error("Failed to fetch offer codes:", err);
        })
        .finally(() => setIsLoading(false));
    }
  }, [productId, defaultDiscountCode]);

  React.useEffect(() => {
    if (!enabled) {
      onDefaultDiscountCodeChange(null);
    } else if (selectedCode) {
      onDefaultDiscountCodeChange(selectedCode.id);
    }
  }, [enabled, selectedCode, onDefaultDiscountCodeChange]);

  const options: Option[] = offerCodes.map((offerCode) => ({
    id: offerCode.code,
    label: offerCode.name,
  }));

  return (
    <ToggleSettingRow
      value={enabled}
      onChange={(value) => {
        setEnabled(value);
        if (!value) {
          setSelectedCode(null);
        }
      }}
      label="Apply discount code automatically"
      dropdown={
        <fieldset>
          <label htmlFor="default-discount-code">Discount code</label>
          {isLoading ? (
            <Select
              inputId="default-discount-code"
              value={null}
              onChange={() => {}}
              options={[]}
              placeholder="Loading..."
              isDisabled
            />
          ) : options.length > 0 ? (
            <Select
              inputId="default-discount-code"
              value={selectedCode}
              onChange={(option) => setSelectedCode(option as Option | null)}
              options={options}
              placeholder="Select a discount code"
              isClearable
            />
          ) : (
            <>
              <input
                id="default-discount-code"
                type="text"
                value=""
                disabled
                placeholder="No discount codes available"
              />
              <small style={{ display: "block", marginTop: "var(--spacer-2)", color: "var(--color-text-secondary)" }}>
                Create discount codes first in the{" "}
                <a href="/checkout/discounts" target="_blank" rel="noreferrer">
                  Discounts page
                </a>
                .
              </small>
            </>
          )}
        </fieldset>
      }
    />
  );
};
