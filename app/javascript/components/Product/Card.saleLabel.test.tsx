// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { CardProduct } from "$app/parsers/product";

import { Card, HorizontalCard } from "$app/components/Product/Card";

vi.mock("$app/utils/user_analytics", () => ({ trackBuyerCurrencyDisplayView: vi.fn() }));
vi.mock("$app/components/useRunOnce", () => ({ useRunOnce: vi.fn() }));
vi.mock("$app/components/Product/Thumbnail", () => ({ Thumbnail: () => null }));

afterEach(cleanup);

const product = (overrides: Partial<CardProduct> = {}): CardProduct => ({
  id: "p1",
  permalink: "sale",
  name: "Sale product",
  seller: null,
  ratings: null,
  price_cents: 1_400,
  original_price_cents: 2_000,
  currency_code: "usd",
  thumbnail_url: null,
  native_type: "digital",
  url: "https://example.com/l/sale",
  is_pay_what_you_want: false,
  quantity_remaining: null,
  is_sales_limited: false,
  duration_in_months: null,
  recurrence: null,
  ...overrides,
});

describe("product card sale label", () => {
  it.each([
    ["Card", Card],
    ["HorizontalCard", HorizontalCard],
  ])("%s shows the label beside the struck-through price", (_name, Component) => {
    render(<Component product={product({ sale_label: "Black Friday" })} />);

    expect(screen.getByTestId("sale-label").textContent).toBe("Black Friday");
    expect(document.querySelector("s")?.textContent).toBe("$20");
  });

  it("shows no label when the presenter sends none", () => {
    render(<Card product={product()} />);

    expect(screen.queryByTestId("sale-label")).toBeNull();
  });
});
