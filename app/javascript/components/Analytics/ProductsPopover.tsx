import { ChevronDown } from "@boxicons/react";
import * as React from "react";

import { type Product } from "$app/components/Analytics";
import { Button } from "$app/components/Button";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Card, CardContent } from "$app/components/ui/Card";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset } from "$app/components/ui/Fieldset";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";

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
      <InputGroup className="whitespace-nowrap">
        <div className="flex-1">Select products...</div>
        <ChevronDown className="size-5" />
      </InputGroup>
    </PopoverTrigger>
    <PopoverContent matchTriggerWidth className="p-0">
      <Card className="border-none shadow-none">
        <CardContent>
          <Fieldset className="grow basis-0">
            <Label>
              <Checkbox
                checked={products.filter((product) => product.selected).length === products.length}
                onChange={(event) =>
                  setProducts((prevProducts) =>
                    prevProducts.map((product) => ({ ...product, selected: event.target.checked })),
                  )
                }
              />
              All products
            </Label>
            {products.map(({ id, name, unique_permalink, selected }) => (
              <Label key={id}>
                <Checkbox
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
              </Label>
            ))}
          </Fieldset>
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
