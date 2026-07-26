// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { PriceInput } from "$app/components/PriceInput";

afterEach(cleanup);

// Tailwind opacity utilities, either unconditional (`opacity-30`) or applied only while the
// element is disabled (`disabled:opacity-100`). Both matter here, because the field under test
// is disabled: matching only the unprefixed form would miss `disabled:opacity-30`, which is what
// the input carries by default.
const OPACITY_UTILITY = /^(?:disabled:)?opacity-(\d+)$/u;

// Tailwind emits opacity utilities in ascending numeric order, so when an element carries more
// than one at equal specificity (the input has both `disabled:opacity-30` from the base styles
// and the `disabled:opacity-100` override) the highest value is the one that actually renders,
// no matter what order the classes appear in. 100 means "not faded".
const effectiveOpacityWhileDisabled = (element: HTMLElement) => {
  const values = element.className
    .split(/\s+/u)
    .map((klass) => OPACITY_UTILITY.exec(klass))
    .filter((match): match is RegExpExecArray => match !== null)
    .map((match) => Number(match[1]));

  return values.length > 0 ? Math.max(...values) : 100;
};

// The currency <select> carries name="Currency" rather than a label, so query it by that. It is
// deliberately invisible (stretched over the currency pill as its hit area), which is why it is
// not reachable through the usual accessible-name queries.
const currencySelect = () => {
  const select = document.querySelector<HTMLSelectElement>('select[name="Currency"]');
  if (!select) throw new Error("currency selector not rendered");
  return select;
};

describe("PriceInput", () => {
  it("shows the amount when disabled", () => {
    render(<PriceInput currencyCode="usd" cents={300} ariaLabel="Minimum amount" disabled />);

    const input = screen.getByLabelText<HTMLInputElement>("Minimum amount");
    expect(input.disabled).toBe(true);
    expect(input.value).toBe("3");

    // The value has to stay legible. A disabled group used to fade its whole subtree with
    // `opacity-30`, which sellers read as an empty field (the PWYW "Minimum amount" mirror).
    // Nothing from the input up to the group may fade the value out — including the input's own
    // `disabled:opacity-30`, which the disabled-group override has to cancel.
    for (let node: HTMLElement | null = input; node; node = node.parentElement) {
      expect(effectiveOpacityWhileDisabled(node)).toBe(100);
    }
  });

  it("keeps the amount editable and visible when enabled", () => {
    render(<PriceInput currencyCode="usd" cents={999} ariaLabel="Amount" onChange={() => {}} />);

    const input = screen.getByLabelText<HTMLInputElement>("Amount");
    expect(input.disabled).toBe(false);
    expect(input.value).toBe("9.99");
  });

  // The currency selector is an invisible <select> stretched over the currency pill. CSS opacity
  // never blocked clicks, so before it was given the real `disabled` attribute a seller could
  // change the currency of a field the UI presents as disabled.
  it("disables the currency selector when disabled", () => {
    render(
      <PriceInput
        currencyCode="usd"
        cents={300}
        ariaLabel="Minimum amount"
        currencyCodeSelector={{ options: ["usd", "eur"], onChange: () => {} }}
        disabled
      />,
    );

    expect(currencySelect().disabled).toBe(true);
  });

  it("leaves the currency selector usable when enabled", () => {
    render(
      <PriceInput
        currencyCode="usd"
        cents={300}
        ariaLabel="Amount"
        onChange={() => {}}
        currencyCodeSelector={{ options: ["usd", "eur"], onChange: () => {} }}
      />,
    );

    expect(currencySelect().disabled).toBe(false);
  });
});
