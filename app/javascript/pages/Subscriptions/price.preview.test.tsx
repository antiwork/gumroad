// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { planChangeDiscount } from "$app/pages/Subscriptions/price";
import type { Discount } from "$app/parsers/checkout";

import {
  ConfigurationSelector,
  type PriceSelection,
  type Product,
} from "$app/components/Product/ConfigurationSelector";

afterEach(cleanup);

const tier = (id: string, priceCents: number): Product["options"][number] => ({
  id,
  name: id,
  quantity_left: null,
  description: "",
  price_difference_cents: 0,
  recurrence_price_values: { monthly: { price_cents: priceCents, suggested_price_cents: null } },
  is_pwyw: false,
  duration_in_minutes: null,
});

const product: Product = {
  id: "membership",
  permalink: "membership",
  rental: null,
  options: [tier("Basic", 1_000), tier("Premium", 2_000)],
  currency_code: "usd",
  price_cents: 0,
  installment_plan: null,
  is_tiered_membership: true,
  is_legacy_subscription: false,
  is_quantity_enabled: false,
  is_multiseat_license: false,
  quantity_remaining: null,
  recurrences: { default: "monthly", enabled: [{ recurrence: "monthly", price_cents: 0, id: "monthly" }] },
  pwyw: null,
  ppp_details: null,
  native_type: "membership",
};

// The renewal serves $3 off while the code is configured for $5 off.
const renewalDiscount: Discount = {
  type: "fixed",
  cents: 300,
  once_per_cart: true,
  once_per_cart_amount_cents: 500,
  product_ids: null,
  expires_at: null,
  minimum_quantity: null,
  duration_in_billing_cycles: null,
  minimum_amount_cents: null,
};

const selection: PriceSelection = {
  rent: false,
  optionId: "Basic",
  price: { value: null, error: false },
  quantity: 1,
  recurrence: "monthly",
  callStartTime: null,
  payInInstallments: false,
};

describe("subscription option previews", () => {
  it("quotes other tiers with the code's served amount", () => {
    render(
      <ConfigurationSelector
        product={product}
        selection={selection}
        discount={renewalDiscount}
        discountForSelection={(previewSelection) =>
          planChangeDiscount({ Basic: renewalDiscount, Premium: renewalDiscount }, renewalDiscount, previewSelection)
        }
        pwywMinimumPriceCents={700}
      />,
    );

    expect(screen.getByRole("radio", { name: "Premium" }).textContent).toContain("$17");
  });
});
