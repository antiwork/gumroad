import { describe, expect, it } from "vitest";

import { isAiProductDetails } from "$app/pages/Products/New";
import { isProductNativeType } from "$app/parsers/product";

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
