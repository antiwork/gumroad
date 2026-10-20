// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import type { Discount } from "$app/parsers/checkout";

import {
  ConfigurationSelector,
  type Option,
  type PriceSelection,
  type Product,
} from "$app/components/Product/ConfigurationSelector";

afterEach(cleanup);

const pwywProduct: Product = {
  id: "product-id",
  permalink: "pwyw-song",
  rental: null,
  options: [],
  currency_code: "usd",
  price_cents: 999,
  installment_plan: null,
  is_tiered_membership: false,
  is_legacy_subscription: false,
  is_quantity_enabled: false,
  is_multiseat_license: false,
  quantity_remaining: null,
  recurrences: null,
  pwyw: { suggested_price_cents: 999 },
  ppp_details: null,
  native_type: "digital",
};

const coffeeProduct: Product = {
  ...pwywProduct,
  permalink: "coffee",
  native_type: "coffee",
  options: [],
  pwyw: { suggested_price_cents: 500 },
};

const initialSelection: PriceSelection = {
  rent: false,
  optionId: null,
  price: { error: false, value: null },
  quantity: 1,
  recurrence: null,
  callStartTime: null,
  payInInstallments: false,
};

const renderPwywSelector = (product: Product = pwywProduct, startingSelection: PriceSelection = initialSelection) => {
  const selections: PriceSelection[] = [];
  const Harness = () => {
    const [selection, setSelection] = React.useState(startingSelection);
    return (
      <ConfigurationSelector
        product={product}
        selection={selection}
        setSelection={(update) => {
          setSelection((prev) => {
            const next = typeof update === "function" ? update(prev) : update;
            selections.push(next);
            return next;
          });
        }}
        discount={null}
      />
    );
  };
  render(<Harness />);
  return { selections };
};

describe("PWYWInput", () => {
  it("exposes a labeled native amount input a screen reader can operate", () => {
    const { selections } = renderPwywSelector();

    const input = screen.getByLabelText("Name a fair price:");
    if (!(input instanceof HTMLInputElement)) throw new Error("expected a native amount <input>");
    expect(input.tagName).toBe("INPUT");
    expect(input.getAttribute("aria-label")).toBeNull();
    expect(screen.queryByLabelText("Price")).toBeNull();

    fireEvent.change(input, { target: { value: "12.50" } });
    expect(selections.at(-1)?.price.value).toBe(1250);
    expect(selections.at(-1)?.price.error).toBe(false);
  });

  it("still names the coffee amount field when the visible label is hidden", () => {
    const { selections } = renderPwywSelector(coffeeProduct);

    const input = screen.getByLabelText("Name a fair price");
    if (!(input instanceof HTMLInputElement)) throw new Error("expected a native amount <input>");
    expect(screen.queryByText("Name a fair price:")).toBeNull();

    fireEvent.change(input, { target: { value: "7" } });
    expect(selections.at(-1)?.price.value).toBe(700);
  });
});

describe("free pay-what-you-want default", () => {
  const freeOption = (id: string, name: string, overrides: Partial<Option> = {}): Option => ({
    id,
    name,
    quantity_left: null,
    description: "",
    price_difference_cents: 0,
    recurrence_price_values: null,
    is_pwyw: false,
    duration_in_minutes: null,
    ...overrides,
  });
  const freeProduct: Product = {
    ...pwywProduct,
    price_cents: 0,
    pwyw: { suggested_price_cents: null, default_price_cents: 0 },
  };
  const freeWithOptions: Product = {
    ...freeProduct,
    options: [freeOption("small", "Small"), freeOption("large", "Large")],
  };
  const chosen: PriceSelection = { ...initialSelection, optionId: "small", price: { error: false, value: 0 } };

  it("keeps the amount at 0 when the buyer picks another free option", () => {
    const { selections } = renderPwywSelector(freeWithOptions, chosen);

    fireEvent.click(screen.getByRole("radio", { name: /Large/u }));

    expect(selections.at(-1)).toMatchObject({ optionId: "large", price: { value: 0, error: false } });
  });

  it("keeps an amount the buyer entered when they pick another free option", () => {
    const { selections } = renderPwywSelector(freeWithOptions, { ...chosen, price: { error: false, value: 500 } });

    fireEvent.click(screen.getByRole("radio", { name: /Large/u }));

    expect(selections.at(-1)).toMatchObject({ optionId: "large", price: { value: 500, error: false } });
  });

  it("keeps an emptied box empty when the buyer picks another free option", () => {
    const { selections } = renderPwywSelector(freeWithOptions, { ...chosen, price: { error: false, value: null } });

    fireEvent.click(screen.getByRole("radio", { name: /Large/u }));

    expect(selections.at(-1)).toMatchObject({ optionId: "large", price: { value: null, error: false } });
  });

  it("clears the amount when the buyer picks an option on a product with a paid option", () => {
    const product = {
      ...freeProduct,
      pwyw: { suggested_price_cents: null, default_price_cents: null },
      options: [freeOption("small", "Small"), freeOption("paid", "Paid", { price_difference_cents: 300 })],
    };
    const { selections } = renderPwywSelector(product, chosen);

    fireEvent.click(screen.getByRole("radio", { name: /Paid/u }));

    expect(selections.at(-1)).toMatchObject({ optionId: "paid", price: { value: null, error: false } });
  });
});

describe("PWYW minimum while the discount is being quoted", () => {
  const product: Product = { ...pwywProduct, price_cents: 1000, pwyw: { suggested_price_cents: null } };
  const sale: Discount = {
    type: "percent",
    percents: 50,
    product_ids: null,
    expires_at: null,
    minimum_quantity: null,
    duration_in_billing_cycles: null,
    minimum_amount_cents: null,
  };
  const Harness = ({ discount, discountPending }: { discount: Discount | null; discountPending: boolean }) => {
    const [selection, setSelection] = React.useState(initialSelection);
    return (
      <ConfigurationSelector
        product={product}
        selection={selection}
        setSelection={setSelection}
        discount={discount}
        discountPending={discountPending}
      />
    );
  };
  const blurWith = (amount: string) => {
    const input = screen.getByLabelText("Name a fair price:");
    fireEvent.change(input, { target: { value: amount } });
    fireEvent.blur(input);
    return input;
  };

  it("checks an amount blurred while quoting against the quoted minimum once it lands", () => {
    const { rerender } = render(<Harness discount={null} discountPending />);
    const input = blurWith("6");
    expect(input.getAttribute("aria-invalid")).toBe("false");

    rerender(<Harness discount={sale} discountPending={false} />);

    expect(input.getAttribute("aria-invalid")).toBe("false");
  });

  it("still flags an amount below the quoted minimum once the quote lands", () => {
    const { rerender } = render(<Harness discount={null} discountPending />);
    const input = blurWith("4");
    expect(input.getAttribute("aria-invalid")).toBe("false");

    rerender(<Harness discount={sale} discountPending={false} />);

    expect(input.getAttribute("aria-invalid")).toBe("true");
  });

  it("checks the amount at once when nothing is being quoted", () => {
    render(<Harness discount={null} discountPending={false} />);

    expect(blurWith("6").getAttribute("aria-invalid")).toBe("true");
  });
});
