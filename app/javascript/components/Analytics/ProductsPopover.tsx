import * as React from "react";

import { type Product } from "$app/components/Analytics";
import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Card, CardContent } from "$app/components/ui/Card";

export type ProductOption = Product & { selected: boolean };

export const ProductsPopover = ({
  products,
  setProducts,
}: {
  products: ProductOption[];
  setProducts: React.Dispatch<React.SetStateAction<ProductOption[]>>;
}) => (
  <Popover>
    <PopoverTrigger>
      <span className="input whitespace-nowrap">
        <div className="fake-input">Select products...</div>
        <Icon name="outline-cheveron-down" />
      </span>
    </PopoverTrigger>
    <PopoverContent matchTriggerWidth className="p-0">
      <Card className="border-none shadow-none">
        <CardContent>
          <fieldset className="grow basis-0">
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
        </CardContent>
        <CardContent>
          <Button
            onClick={() =>
              setProducts((prevProducts) =>
                prevProducts.map((product) => ({ ...product, selected: !product.selected })),
              )
            }
            className="grow basis-0"
          >
            Toggle selected
          </Button>
        </CardContent>
      </Card>
    </PopoverContent>
  </Popover>
);
