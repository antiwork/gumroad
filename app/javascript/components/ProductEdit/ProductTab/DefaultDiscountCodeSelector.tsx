import * as React from "react";

import { searchProductOfferCodes } from "$app/data/offer_code";
import { assertResponseError } from "$app/utils/request";

import { ComboBox } from "$app/components/ComboBox";
import { ProductEditContext, AvailableDiscountCode } from "$app/components/ProductEdit/state";
import { showAlert } from "$app/components/server-components/Alert";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";

export const DefaultDiscountCodeSelector = () => {
  const context = React.useContext(ProductEditContext);

  if (!context?.availableDiscountCodes) return null;

  const { uniquePermalink, product, updateProduct, availableDiscountCodes, setAvailableDiscountCodes } = context;

  const defaultOfferCodeId = product.default_offer_code_id;
  const isEnabled = !!defaultOfferCodeId;

  const selectedDiscountCode = availableDiscountCodes.find((code) => code.id === defaultOfferCodeId) ?? null;

  const formatLabel = (code: AvailableDiscountCode) => code.name || code.code;

  const [query, setQuery] = React.useState<string>(() =>
    selectedDiscountCode ? formatLabel(selectedDiscountCode) : "",
  );
  const [options, setOptions] = React.useState<AvailableDiscountCode[]>(availableDiscountCodes ?? []);
  const [isOpen, setIsOpen] = React.useState(false);

  const loadOptions = React.useCallback(
    async (search: string) => {
      if (!uniquePermalink) return;

      try {
        const results = await searchProductOfferCodes(uniquePermalink, search.trim());
        setOptions(results);
      } catch (error) {
        assertResponseError(error);
        showAlert("Sorry, something went wrong while searching discount codes.", "error");
      }
    },
    [uniquePermalink],
  );

  const debouncedLoadOptions = useDebouncedCallback((search: string) => {
    void loadOptions(search);
  }, 300);

  const handleToggleChange = (enabled: boolean) => {
    if (enabled) {
      const firstDiscountCode = availableDiscountCodes[0];
      if (!defaultOfferCodeId && firstDiscountCode) {
        updateProduct({ default_offer_code_id: firstDiscountCode.id });
        setQuery(formatLabel(firstDiscountCode));
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
              open={isOpen ? options.length > 0 : false}
              onToggle={setIsOpen}
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
                      setIsOpen(true);
                    }}
                    aria-autocomplete="list"
                  />
                </div>
              )}
              options={options}
              option={(code, props) => (
                <div
                  {...props}
                  onClick={(event: React.MouseEvent<HTMLDivElement>) => {
                    if (props.onClick) {
                      props.onClick(event);
                    }
                    updateProduct({ default_offer_code_id: code.id });
                    setQuery(formatLabel(code));
                    setAvailableDiscountCodes((current) => {
                      if (!current) return [code];
                      if (current.find((c) => c.id === code.id)) return current;
                      return [code, ...current];
                    });
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
