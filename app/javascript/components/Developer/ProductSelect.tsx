import * as React from "react";

import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";

export type Product = {
  name: string;
  script_base_url: string;
  url: string;
  gumroad_domain_url: string;
};

export const ProductSelect = ({
  products,
  affiliatedProducts,
  selectedProductUrl,
  onProductSelectChange,
}: {
  products: Product[];
  affiliatedProducts: Product[];
  selectedProductUrl: string;
  onProductSelectChange: (product: Product) => void;
}) => {
  const uid = React.useId();

  const dispatchChangeEvent = (evt: React.ChangeEvent<HTMLSelectElement>) => {
    const product =
      products.find((product) => product.url === evt.target.value) ||
      affiliatedProducts.find((product) => product.url === evt.target.value);
    if (product) onProductSelectChange(product);
    return true;
  };

  return (
    <Fieldset>
      <FieldsetTitle>
        <Label htmlFor={uid}>Choose your product</Label>
      </FieldsetTitle>
      <Select id={uid} value={selectedProductUrl} onChange={dispatchChangeEvent}>
        <optgroup label="Your products">
          {products.map((product) => (
            <option key={product.url} value={product.url}>
              {product.name}
            </option>
          ))}
        </optgroup>

        {affiliatedProducts.length !== 0 ? (
          <optgroup label="Affiliated products">
            {affiliatedProducts.map((affiliatedProduct) => (
              <option key={affiliatedProduct.url} value={affiliatedProduct.url}>
                {affiliatedProduct.name}
              </option>
            ))}
          </optgroup>
        ) : null}
      </Select>
    </Fieldset>
  );
};
