import * as React from "react";
import { cast } from "ts-safe-cast";

import { ProductNativeType } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { DiscountInput, InputtedDiscount } from "$app/components/CheckoutDashboard/DiscountInput";
import { Details } from "$app/components/Details";
import { Modal } from "$app/components/Modal";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { useRunOnce } from "$app/components/useRunOnce";

export type Product = {
  id: string;
  name: string;
  price_cents: number;
  currency_code: CurrencyCode;
  review_count: number;
  average_rating: number;
  native_type: ProductNativeType;
};

export const UpsellSelectModal = ({
  isOpen,
  onClose,
  onInsert,
}: {
  isOpen: boolean;
  onClose: () => void;
  onInsert: (product: Product, discount: InputtedDiscount | null) => void;
}) => {
  const [selectedProduct, setSelectedProduct] = React.useState<Product | null>(null);
  const [discount, setDiscount] = React.useState<InputtedDiscount | null>(null);

  const [products, setProducts] = React.useState<Product[] | null>(null);
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
      onInsert(selectedProduct, discount);
    }
  };

  return (
    <Modal
      open={isOpen}
      onClose={onClose}
      title="Insert upsell"
      footer={
        <>
          <Button onClick={onClose}>Cancel</Button>
          <Button color="primary" onClick={handleInsert} disabled={selectedProduct === null}>
            Insert
          </Button>
        </>
      }
    >
      <fieldset>
        <legend>
          <label htmlFor="product-select">Product</label>
        </legend>
        <Select
          inputId="product-select"
          options={products?.map((product) => ({
            id: product.id,
            label: product.name,
          }))}
          value={
            selectedProduct
              ? {
                  id: selectedProduct.id,
                  label: selectedProduct.name,
                }
              : null
          }
          onChange={(newValue) => {
            if (newValue && typeof newValue === "object" && "id" in newValue) {
              setSelectedProduct(products?.find((p) => p.id === newValue.id) || null);
            } else {
              setSelectedProduct(null);
            }
          }}
          placeholder="Select a product"
          isClearable
          isDisabled={products === null}
        />
      </fieldset>
      <fieldset>
        <legend>
          <label htmlFor="discount">Discount</label>
        </legend>
        <Details
          className="toggle"
          open={!!discount}
          summary={
            <label>
              <input
                type="checkbox"
                role="switch"
                checked={!!discount}
                onChange={(evt) => setDiscount(evt.target.checked ? { type: "percent", value: 0 } : null)}
              />
              Add a discount to the offered product
            </label>
          }
        >
          {discount && selectedProduct ? (
            <div className="dropdown" style={{ maxWidth: "400px" }}>
              <DiscountInput
                discount={discount}
                setDiscount={(newDiscount: InputtedDiscount) => setDiscount(newDiscount)}
                currencyCode={selectedProduct.currency_code}
              />
            </div>
          ) : null}
        </Details>
      </fieldset>
    </Modal>
  );
};
