// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { PriceInput } from "$app/components/PriceInput";

afterEach(cleanup);

const fadingOpacityClasses = (element: HTMLElement) =>
  element.className.split(/\s+/u).filter((klass) => /^opacity-(?!100$)/u.test(klass));

describe("PriceInput", () => {
  it("shows the amount when disabled", () => {
    render(<PriceInput currencyCode="usd" cents={300} ariaLabel="Minimum amount" disabled />);

    const input = screen.getByLabelText<HTMLInputElement>("Minimum amount");
    expect(input.disabled).toBe(true);
    expect(input.value).toBe("3");

    // The value has to stay legible. A disabled group used to fade its whole subtree with
    // `opacity-30`, which sellers read as an empty field (the PWYW "Minimum amount" mirror).
    // Nothing from the input up to the group may fade the value out.
    for (let node: HTMLElement | null = input; node; node = node.parentElement) {
      expect(fadingOpacityClasses(node)).toEqual([]);
    }
  });

  it("keeps the amount editable and visible when enabled", () => {
    render(<PriceInput currencyCode="usd" cents={999} ariaLabel="Amount" onChange={() => {}} />);

    const input = screen.getByLabelText<HTMLInputElement>("Amount");
    expect(input.disabled).toBe(false);
    expect(input.value).toBe("9.99");
  });
});
