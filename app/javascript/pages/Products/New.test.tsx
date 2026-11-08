// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { set } from "lodash-es";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import NewProductPage, { isAiProductDetails } from "$app/pages/Products/New";
import { isProductNativeType } from "$app/parsers/product";

vi.mock("@inertiajs/react", () => ({
  Link: () => null,
  usePage: () => ({
    props: {
      current_seller_currency_code: "usd",
      native_product_types: ["digital", "course"],
      service_product_types: ["call", "coffee"],
      release_at_date: "",
      show_orientation_text: false,
      eligible_for_service_products: true,
      ai_generation_enabled: false,
      ai_promo_dismissed: true,
      is_mobile_app_web_view: true,
    },
  }),
  // Keeps form state so a change (for example the currency) re-renders the page like Inertia's form.
  useForm: <T extends object>(_key: string, initial: T) => {
    const [data, setState] = React.useState(initial);
    const setData = (path: string, value: unknown) => setState((current) => set(structuredClone(current), path, value));
    return { data, errors: {}, processing: false, setData, clearErrors: vi.fn() };
  },
}));

const details = {
  name: "Watercolor brushes",
  description: "<p>Twelve brushes.</p>",
  summary: "Twelve brushes",
  price: 12,
  currency_code: "usd",
  price_frequency_in_months: null,
  native_type: "digital",
  number_of_content_pages: 3,
};

describe("isAiProductDetails", () => {
  it("accepts complete product details", () => {
    expect(isAiProductDetails(details)).toBe(true);
    expect(isAiProductDetails({ ...details, native_type: "membership", price_frequency_in_months: 1 })).toBe(true);
  });

  it("rejects details the model left incomplete or invalid", () => {
    expect(isAiProductDetails({ ...details, name: null })).toBe(false);
    expect(isAiProductDetails({ ...details, price: "12" })).toBe(false);
    expect(isAiProductDetails({ ...details, native_type: "software" })).toBe(false);
    expect(isAiProductDetails(null)).toBe(false);
  });
});

describe("isProductNativeType", () => {
  it("accepts product and service types only", () => {
    expect(isProductNativeType("bundle")).toBe(true);
    expect(isProductNativeType("coffee")).toBe(true);
    expect(isProductNativeType("software")).toBe(false);
  });
});

describe("NewProductPage", () => {
  afterEach(cleanup);

  it("names each product type picker after its heading", () => {
    render(<NewProductPage />);

    expect(screen.getByRole("radiogroup", { name: "Products" })).toBeDefined();
    expect(screen.getByRole("radiogroup", { name: "Services" })).toBeDefined();
  });

  it("explains how the Price field reads a comma in the selected currency", () => {
    render(<NewProductPage />);
    const describedPrice = (description: string) => screen.getByRole("textbox", { name: "Price", description });

    expect(describedPrice("Use a comma for thousands (7,900) or for cents (7,90).")).toBeDefined();

    fireEvent.change(screen.getByLabelText("Currency"), { target: { value: "jpy" } });
    expect(describedPrice("Use a comma for thousands (7,900).")).toBeDefined();

    fireEvent.change(screen.getByLabelText("Currency"), { target: { value: "cop" } });
    expect(describedPrice("Use a comma for thousands (7,900) or for cents (7,90).")).toBeDefined();
  });
});
