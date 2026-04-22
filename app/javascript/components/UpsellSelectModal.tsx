import * as React from "react";
import { cast } from "ts-safe-cast";

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
  useRunOnce(() => {
    const fetchProducts = async () => {
      try {
        const response = await request({
          method: "GET",
          accept: "json",
          url: Routes.checkout_upsells_products_path(),
        });
        const responseData = cast<Product[]>(await response.json());
        setProducts(responseData);
      } catch (error) {
        assertResponseError(error);
        showAlert(error.message, "error");
      }
    };

    void fetchProducts();
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
            }
          }}
          placeholder="Select a product"
          isClearable
          isDisabled={products.length === 0}
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
