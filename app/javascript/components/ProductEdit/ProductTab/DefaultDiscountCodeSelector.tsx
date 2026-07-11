import { ChevronDown } from "@boxicons/react";
import * as React from "react";

import { searchProductOfferCodes } from "$app/data/offer_code";
import { assertResponseError } from "$app/utils/request";

import { ComboBox } from "$app/components/ComboBox";
import { OfferCode } from "$app/components/ProductEdit/state";
import { showAlert } from "$app/components/server-components/Alert";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";

// This selector is shared between the regular product editor (which stores its
// state in ProductEditContext) and the bundle editor (which uses Inertia form
// state), so it takes its value and change handler as plain props instead of
// reading a specific state store.
export const DefaultDiscountCodeSelector = ({
  uniquePermalink,
  selectedOfferCode,
  onChange,
}: {
  uniquePermalink: string;
  selectedOfferCode: OfferCode | null;
  onChange: (offerCode: OfferCode | null) => void;
}) => {
  const getLabel = (code: OfferCode) => code.name || code.code;

  const [query, setQuery] = React.useState(() => (selectedOfferCode ? getLabel(selectedOfferCode) : ""));
  const [options, setOptions] = React.useState<OfferCode[]>([]);
  const [isOpen, setIsOpen] = React.useState(false);
  // Start the toggle in the "on" position when the editor opens with a default
  // code already selected, so it doesn't flash from off to on during the first render.
  const [isToggleOn, setIsToggleOn] = React.useState(() => Boolean(selectedOfferCode));

  const resetSearch = React.useCallback(() => {
    setQuery("");
    setOptions([]);
    setIsOpen(false);
  }, []);

  React.useEffect(() => {
    if (selectedOfferCode) {
      setIsToggleOn(true);
    }
  }, [selectedOfferCode]);

  const fetchOptions = React.useCallback(
    async (search: string) => {
      if (!uniquePermalink) return;

      const trimmedSearch = search.trim();

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
        setIsToggleOn(true);
        resetSearch();
      } else {
        onChange(null);
        setIsToggleOn(false);
        resetSearch();
      }
    },
    [resetSearch, onChange],
  );

  return (
    <ToggleSettingRow
      value={isToggleOn}
      onChange={handleToggleChange}
      label="Automatically apply discount code"
      dropdown={
        <section className="flex flex-col gap-4">
          <Fieldset>
            <Label htmlFor="default-discount-code">Discount code</Label>
            <ComboBox<OfferCode>
              editable
              open={isOpen ? options.length > 0 : false}
              onToggle={setIsOpen}
              className="w-full"
              options={options}
              maxHeight="16rem"
              onFocus={() => {
                if (!query.trim()) {
                  void fetchOptions("");
                }
              }}
              input={(props) => (
                <InputGroup>
                  <Input
                    {...props}
                    id="default-discount-code"
                    type="search"
                    placeholder="Begin typing to select a discount code"
                    value={query}
                    aria-autocomplete="list"
                    onChange={(event) => {
                      const value = event.target.value;
                      setQuery(value);

                      debouncedFetchOptions(value);
                      setIsOpen(true);
                    }}
                  />
                  <ChevronDown className="size-5" />
                </InputGroup>
              )}
              option={(code, props) => (
                <div
                  {...props}
                  aria-selected={code.id === selectedOfferCode?.id}
                  onClick={(event) => {
                    props.onClick?.(event);

                    onChange(code);

                    setQuery(getLabel(code));
                    setIsOpen(false);
                  }}
                >
                  {getLabel(code)}
                </div>
              )}
            />
          </Fieldset>
        </section>
      }
    />
  );
};
