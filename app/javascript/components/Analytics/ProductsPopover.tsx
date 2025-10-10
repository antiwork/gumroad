import * as React from "react";

import { type Product } from "$app/components/Analytics";
import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";

export type ProductOption = Product & { selected: boolean };

export const ProductsPopover = ({
  products,
  setProducts,
}: {
  products: ProductOption[];
  setProducts: React.Dispatch<React.SetStateAction<ProductOption[]>>;
}) => (
  <Popover
    trigger={
      <span className="input">
        <div className="fake-input">Select products...</div>
        <Icon name="outline-cheveron-down" />
      </span>
    }
  >
    <div className="stack">
      <div>
        <fieldset>
          <label>
            <input
              type="checkbox"
              checked={products.filter((product) => product.selected).length === products.length}
              onChange={(event) =>
                setProducts((prevProducts) =>
                  prevProducts.map((product) => ({ ...product, selected: event.target.checked })),
                )
              }
            />
            All products
          </label>
          {products.map(({ id, name, unique_permalink, selected }) => (
            <label key={id}>
              <input
                type="checkbox"
                checked={selected}
                onChange={(event) =>
                  setProducts((prevProducts) =>
                    prevProducts.map((product) =>
                      product.unique_permalink === unique_permalink
                        ? { ...product, selected: event.target.checked }
                        : product,
                    ),
                  )
                }
              />
              {name}
            </label>
          ))}
        </fieldset>
      </div>
      <div>
        <Button
          onClick={() =>
            setProducts((prevProducts) => prevProducts.map((product) => ({ ...product, selected: !product.selected })))
          }
        >
          Toggle selected
        </Button>
      </div>
    </div>
  </Popover>
);
