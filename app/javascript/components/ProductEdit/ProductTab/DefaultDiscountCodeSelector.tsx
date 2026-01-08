import * as React from "react";

import { searchProductOfferCodes } from "$app/data/offer_code";
import { assertResponseError } from "$app/utils/request";

import { ComboBox } from "$app/components/ComboBox";
import { OfferCode, useProductEditContext } from "$app/components/ProductEdit/state";
import { showAlert } from "$app/components/server-components/Alert";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";

export const DefaultDiscountCodeSelector = () => {
  const { uniquePermalink, product, updateProduct } = useProductEditContext();

  const selectedDiscountCode = product.default_offer_code;

  const getLabel = (code: OfferCode) => code.name || code.code;

  const [query, setQuery] = React.useState(() => (selectedDiscountCode ? getLabel(selectedDiscountCode) : ""));
  const [options, setOptions] = React.useState<OfferCode[]>([]);
  const [isOpen, setIsOpen] = React.useState(false);
  const [isTogglePending, setIsTogglePending] = React.useState(false);

  const resetSearch = React.useCallback(() => {
    setQuery("");
    setOptions([]);
    setIsOpen(false);
  }, []);

  React.useEffect(() => {
    if (product.default_offer_code) {
      setIsTogglePending(false);
    }
  }, [product.default_offer_code]);

  const fetchOptions = React.useCallback(
    async (search: string) => {
      if (!uniquePermalink) return;

      const trimmedSearch = search.trim();
      if (!trimmedSearch) {
        resetSearch();
        return;
      }

      try {
        const results = await searchProductOfferCodes(uniquePermalink, trimmedSearch);
        setOptions(results);
      } catch (error) {
        assertResponseError(error);
        showAlert("Sorry, something went wrong while searching discount codes.", "error");
      }
    },
    [uniquePermalink, resetSearch],
  );

  const debouncedFetchOptions = useDebouncedCallback((search: string) => void fetchOptions(search), 300);

  const handleToggleChange = React.useCallback(
    (enabled: boolean) => {
      if (enabled) {
        setIsTogglePending(true);
        resetSearch();
      } else {
        updateProduct({ default_offer_code_id: null });
        setIsTogglePending(false);
        resetSearch();
      }
    },
    [resetSearch, updateProduct],
  );

  return (
    <ToggleSettingRow
      value={!!product.default_offer_code || isTogglePending}
      onChange={handleToggleChange}
      label="Automatically apply discount code"
      dropdown={
        <section className="flex flex-col gap-4">
          <fieldset>
            <label htmlFor="default-discount-code">Discount code</label>
            <ComboBox<OfferCode>
              editable
              open={isOpen ? options.length > 0 : false}
              onToggle={setIsOpen}
              className="w-full"
              options={options}
              input={(props) => (
                <div className="input">
                  <input
                    {...props}
                    id="default-discount-code"
                    type="search"
                    placeholder="Begin typing to select a discount code"
                    value={query}
                    aria-autocomplete="list"
                    onChange={(event) => {
                      const value = event.target.value;
                      setQuery(value);

                      if (!value.trim()) {
                        resetSearch();
                        return;
                      }

                      debouncedFetchOptions(value);
                      setIsOpen(true);
                    }}
                  />
                </div>
              )}
              option={(code, props) => (
                <div
                  {...props}
                  aria-selected={code.id === product.default_offer_code?.id}
                  onClick={(event) => {
                    props.onClick?.(event);

                    updateProduct({
                      default_offer_code_id: code.id,
                    });

                    setQuery(getLabel(code));
                    setIsTogglePending(false);
                    setIsOpen(false);
                  }}
                >
                  {getLabel(code)}
                </div>
              )}
            />
          </fieldset>
        </section>
      }
    />
  );
};
