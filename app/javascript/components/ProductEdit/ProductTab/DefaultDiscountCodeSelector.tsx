import * as React from "react";

import { ComboBox } from "$app/components/ComboBox";
import { ProductEditContext, AvailableDiscountCode } from "$app/components/ProductEdit/state";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { searchProductOfferCodes } from "$app/data/offer_code";
import { assertResponseError } from "$app/utils/request";
import { showAlert } from "$app/components/server-components/Alert";

export const DefaultDiscountCodeSelector = () => {
  const context = React.useContext(ProductEditContext);
  if (!context) return null;

  const { uniquePermalink, product, updateProduct, availableDiscountCodes } = context;
  const defaultOfferCodeId = product.default_offer_code_id;

  const isEnabled = !!defaultOfferCodeId;

  const selectedDiscountCode = availableDiscountCodes?.find((code) => code.id === defaultOfferCodeId) ?? null;

  const [query, setQuery] = React.useState("");
  const [options, setOptions] = React.useState<AvailableDiscountCode[]>(availableDiscountCodes ?? []);

  const formatLabel = (code: AvailableDiscountCode) => {
    const labelBase = code.name || code.code;
    return labelBase;
  };

  const loadOptions = React.useCallback(
    async (search: string) => {
      if (!uniquePermalink) return;

      const trimmed = search.trim();
      if (!trimmed) {
        setOptions(availableDiscountCodes ?? []);
        return;
      }

      try {
        const results = await searchProductOfferCodes(uniquePermalink, trimmed);
        setOptions(results as AvailableDiscountCode[]);
      } catch (e) {
        assertResponseError(e);
        showAlert("Sorry, something went wrong while searching discount codes.", "error");
      }
    },
    [availableDiscountCodes, uniquePermalink],
  );

  const debouncedLoadOptions = useDebouncedCallback((search: string) => {
    void loadOptions(search);
  }, 300);

  React.useEffect(() => {
    if (selectedDiscountCode) {
      setQuery(formatLabel(selectedDiscountCode));
      setOptions((prev) => {
        if (prev.find((code) => code.id === selectedDiscountCode.id)) return prev;
        return [selectedDiscountCode, ...prev];
      });
    } else if (!defaultOfferCodeId) {
      setQuery("");
    }
  }, [defaultOfferCodeId, selectedDiscountCode]);
  const filteredCodes = query
    ? options.filter((code) => formatLabel(code).toLowerCase().includes(query.toLowerCase()))
    : options;

  const handleToggleChange = (enabled: boolean) => {
    if (enabled) {
      const firstDiscountCode = availableDiscountCodes?.[0];
      if (!defaultOfferCodeId && firstDiscountCode) {
        updateProduct({ default_offer_code_id: firstDiscountCode.id });
      }
    } else {
      updateProduct({ default_offer_code_id: null });
      setQuery("");
    }
  };

  return (
    <ToggleSettingRow
      value={isEnabled}
      onChange={handleToggleChange}
      disabled={false}
      label="Automatically apply discount code"
      dropdown={
        <section className="flex flex-col gap-4">
          <fieldset>
            <label htmlFor="default-discount-code">Discount code</label>
            <ComboBox<AvailableDiscountCode>
              editable
              className="w-full"
              input={(props) => (
                <div className="input">
                  <input
                    {...props}
                    id="default-discount-code"
                    type="search"
                    placeholder="Search discount codes"
                    value={query}
                    onChange={(event) => {
                      const value = event.target.value;
                      setQuery(value);
                      debouncedLoadOptions(value);
                    }}
                    aria-autocomplete="list"
                  />
                </div>
              )}
              options={filteredCodes}
              option={(code, props) => (
                <div
                  {...props}
                  onClick={(event) => {
                    props.onClick?.(event);
                    updateProduct({ default_offer_code_id: code.id });
                    setQuery(formatLabel(code));
                  }}
                  aria-selected={code.id === defaultOfferCodeId}
                >
                  {formatLabel(code)}
                </div>
              )}
            />
          </fieldset>
        </section>
      }
    />
  );
};
