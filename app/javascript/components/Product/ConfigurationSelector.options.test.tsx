// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import {
  ConfigurationSelector,
  type PriceSelection,
  type Product,
} from "$app/components/Product/ConfigurationSelector";

afterEach(cleanup);

const versionedProduct: Product = {
  permalink: "album",
  rental: null,
  options: [
    {
      id: "opt-listener",
      name: "Listener's Edition",
      quantity_left: null,
      description: "Enjoy the complete album in a simple digital edition.",
      price_difference_cents: 0,
      recurrence_price_values: null,
      is_pwyw: false,
      duration_in_minutes: null,
    },
    {
      id: "opt-collector",
      name: "Collector's Edition",
      quantity_left: null,
      description: "",
      price_difference_cents: 500,
      recurrence_price_values: null,
      is_pwyw: false,
      duration_in_minutes: null,
    },
  ],
  currency_code: "usd",
  price_cents: 999,
  installment_plan: null,
  is_tiered_membership: false,
  is_legacy_subscription: false,
  is_quantity_enabled: false,
  is_multiseat_license: false,
  quantity_remaining: null,
  recurrences: null,
  pwyw: null,
  ppp_details: null,
  native_type: "digital",
};

const initialSelection: PriceSelection = {
  rent: false,
  optionId: "opt-listener",
  price: { error: false, value: null },
  quantity: 1,
  recurrence: null,
  callStartTime: null,
  payInInstallments: false,
};

const renderSelector = () => {
  const Harness = () => {
    const [selection, setSelection] = React.useState(initialSelection);
    return (
      <ConfigurationSelector
        product={versionedProduct}
        selection={selection}
        setSelection={setSelection}
        discount={null}
      />
    );
  };
  render(<Harness />);
};

describe("version selector accessibility", () => {
  it("exposes each version's description to screen readers via aria-describedby", () => {
    renderSelector();

    const radio = screen.getByRole("radio", { name: "Listener's Edition" });
    const describedBy = radio.getAttribute("aria-describedby");
    if (!describedBy) throw new Error("expected aria-describedby on the version radio");
    const description = document.getElementById(describedBy);
    expect(description?.textContent).toBe("Enjoy the complete album in a simple digital edition.");
  });

  it("omits aria-describedby when a version has no description", () => {
    renderSelector();

    const radio = screen.getByRole("radio", { name: "Collector's Edition" });
    expect(radio.getAttribute("aria-describedby")).toBeNull();
  });
});
