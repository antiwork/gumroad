import * as React from "react";
import typia from "typia";

import { ProductNativeType } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { DiscountInput, InputtedDiscount } from "$app/components/CheckoutDashboard/DiscountInput";
import { Dropdown } from "$app/components/Dropdown";
import { Modal } from "$app/components/Modal";
import { RecurrencePriceValue } from "$app/components/ProductEdit/state";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";
import { Switch } from "$app/components/ui/Switch";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useRunOnce } from "$app/components/useRunOnce";

export type ProductOption = {
  id: string;
  name: string;
  description: string;
  duration_in_minutes: number | null;
  is_pwyw: boolean;
  price_difference_cents: number;
  quantity_left: number | null;
  recurrence_price_values: RecurrencePriceValue[] | null;
};

export type Product = {
  id: string;
  name: string;
  price_cents: number;
  currency_code: CurrencyCode;
  review_count: number;
  average_rating: number;
  native_type: ProductNativeType;
  options: ProductOption[];
};

export const UpsellSelectModal = ({
  isOpen,
  onClose,
  onInsert,
}: {
  isOpen: boolean;
  onClose: () => void;
  onInsert: (product: Product, variant: ProductOption | null, discount: InputtedDiscount | null) => void;
}) => {
  const [selectedProduct, setSelectedProduct] = React.useState<Product | null>(null);
  const [discount, setDiscount] = React.useState<InputtedDiscount | null>(null);
  const [selectedVariant, setSelectedVariant] = React.useState<ProductOption | null>(null);

  const [products, setProducts] = React.useState<Product[]>([]);
  const [isLoading, setIsLoading] = React.useState(false);
  const activeRequestId = React.useRef(0);

  // The server returns at most 25 products per request, so sellers with larger
  // catalogs must search server-side to reach their older products. Each
  // keystroke (debounced below) re-fetches the option list with the typed text.
  const fetchProducts = async (query: string) => {
    const requestId = ++activeRequestId.current;
    setIsLoading(true);
    try {
      const response = await request({
        method: "GET",
        accept: "json",
        url: Routes.checkout_upsells_products_path(query.trim() !== "" ? { query: query.trim() } : {}),
      });
      const responseData = typia.assert<Product[]>(await response.json());
      // Ignore out-of-order responses: only the latest request may update the list.
      if (requestId === activeRequestId.current) setProducts(responseData);
    } catch (error) {
      assertResponseError(error);
      if (requestId === activeRequestId.current) showAlert(error.message, "error");
    } finally {
      if (requestId === activeRequestId.current) setIsLoading(false);
    }
  };

  const debouncedFetchProducts = useDebouncedCallback((query: string) => void fetchProducts(query), 300);

  useRunOnce(() => {
    void fetchProducts("");
  });

  const handleInsert = () => {
    if (selectedProduct) {
      onInsert(selectedProduct, selectedVariant, discount);
    }
  };

  type ProductSelectOption = {
    id: string;
    label: string;
    variantId?: string;
    isSubOption?: boolean;
    disabled?: boolean;
  };

  const productOptions: ProductSelectOption[] = products.reduce<ProductSelectOption[]>(
    (selectOptions, { id, name, options }) => {
      const hasVariants = options.length > 0;
      selectOptions.push({ id, label: name, disabled: hasVariants });

      if (hasVariants) {
        options.forEach(({ id: variantId, name: variantName }) => {
          selectOptions.push({ id, label: `${name} (${variantName})`, variantId, isSubOption: true });
        });
      }

      return selectOptions;
    },
    [],
  );

  const selectProductOption = (newProductOption: { id: string; label: string; variantId?: string } | null) => {
    const product = products.find((p) => p.id === newProductOption?.id) || null;
    setSelectedProduct(product);

    const variant = product?.options.find((o) => o.id === newProductOption?.variantId) || null;
    setSelectedVariant(variant);
  };

  const selectedProductOption = selectedProduct
    ? {
        id: selectedProduct.id,
        label: selectedVariant ? `${selectedProduct.name} (${selectedVariant.name})` : selectedProduct.name,
      }
    : null;

  return (
    <Modal
      open={isOpen}
      onClose={onClose}
      title="Insert upsell"
      footer={
        <>
          <Button onClick={onClose}>Cancel</Button>
          <Button color="primary" onClick={handleInsert} disabled={!selectedProduct}>
            Insert
          </Button>
        </>
      }
    >
      <Fieldset>
        <FieldsetTitle>
          <Label htmlFor="product-select">Product</Label>
        </FieldsetTitle>
        <Select
          inputId="product-select"
          options={productOptions}
          value={selectedProductOption}
          onChange={(newValue) => {
            if (newValue && typeof newValue === "object" && "id" in newValue) {
              selectProductOption(newValue);
            } else {
              selectProductOption(null);
              // Clearing the selection also resets the option list to the full
              // (unfiltered) catalog — otherwise the dropdown would keep showing
              // only the results of the last search. Cancel any search that is
              // still waiting on the debounce timer first, so it can't fire
              // after this reset and put the stale filtered results back.
              debouncedFetchProducts.cancel();
              void fetchProducts("");
            }
          }}
          onInputChange={(inputValue, { action }) => {
            // Only refetch on real typing. react-select also fires this event with
            // an empty value when the input blurs or an option is chosen, and
            // refetching then would needlessly reset the list.
            if (action === "input-change") debouncedFetchProducts(inputValue);
          }}
          isLoading={isLoading}
          placeholder="Select a product"
          isClearable
        />
      </Fieldset>

      <Fieldset>
        <FieldsetTitle>
          <Label htmlFor="discount">Discount</Label>
        </FieldsetTitle>
        <Details open={!!discount}>
          <DetailsToggle chevronPosition="none" className="mb-0">
            <Switch
              checked={!!discount}
              onChange={(evt) => setDiscount(evt.target.checked ? { type: "percent", value: 0 } : null)}
              label="Add a discount to the offered product"
            />
          </DetailsToggle>
          {discount && selectedProduct ? (
            <Dropdown className="max-w-sm">
              <DiscountInput
                discount={discount}
                setDiscount={(newDiscount: InputtedDiscount) => setDiscount(newDiscount)}
                currencyCode={selectedProduct.currency_code}
              />
            </Dropdown>
          ) : null}
        </Details>
      </Fieldset>
    </Modal>
  );
};
