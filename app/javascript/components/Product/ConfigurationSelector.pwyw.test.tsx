// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import {
  ConfigurationSelector,
  type PriceSelection,
  type Product,
} from "$app/components/Product/ConfigurationSelector";

afterEach(cleanup);

const pwywProduct: Product = {
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

const renderPwywSelector = (product: Product = pwywProduct) => {
  const selections: PriceSelection[] = [];
  const Harness = () => {
    const [selection, setSelection] = React.useState(initialSelection);
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
