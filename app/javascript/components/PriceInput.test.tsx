// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

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

  // `name` is a form-submission attribute, not an accessible name, so the accessibility tree
  // reported this combobox with an empty name and a screen reader announced it unlabelled.
  it("gives the currency selector an accessible name", () => {
    render(
      <PriceInput
        currencyCode="usd"
        cents={300}
        ariaLabel="Amount"
        onChange={() => {}}
        currencyCodeSelector={{ options: ["usd", "eur"], onChange: () => {} }}
      />,
    );

    expect(screen.getByLabelText<HTMLSelectElement>("Currency")).toBe(currencySelect());
  });

  // SEK, NOK and DKK share "kr" as their symbol, so labelling the menu by symbol alone made the
  // three options indistinguishable. The menu carries the name; the pill next to the amount does
  // not need one.
  it("labels currency options with the currency name, not just the symbol", () => {
    render(
      <PriceInput
        currencyCode="sek"
        cents={300}
        ariaLabel="Amount"
        onChange={() => {}}
        currencyCodeSelector={{ options: ["sek", "nok", "dkk"], onChange: () => {} }}
      />,
    );

    expect(Array.from(currencySelect().options).map((option) => option.textContent)).toEqual([
      "kr (Swedish Krona)",
      "kr (Norwegian Krone)",
      "kr (Danish Krone)",
    ]);
  });
});

describe("PriceInput amount typing", () => {
  type AmountCurrency = "usd" | "krw" | "eur";

  // Holds a number and echoes cents back the way PriceEditor does, so the field's resync from
  // `cents` runs too.
  const ControlledPriceInput = ({
    currencyCode,
    onChange,
  }: {
    currencyCode: AmountCurrency;
    onChange: (cents: number | null) => void;
  }) => {
    const [cents, setCents] = React.useState(0);
    return (
      <PriceInput
        currencyCode={currencyCode}
        cents={cents}
        ariaLabel="Amount"
        onChange={(newCents) => {
          onChange(newCents);
          setCents(newCents ?? 0);
        }}
      />
    );
  };

  const renderAmount = (currencyCode: AmountCurrency) => {
    const onChange = vi.fn();
    render(<ControlledPriceInput currencyCode={currencyCode} onChange={onChange} />);
    const input = screen.getByLabelText<HTMLInputElement>("Amount");
    // Cleared over a parent that already holds 0, so reporting 0 does not re-render the field.
    fireEvent.change(input, { target: { value: "" } });
    // Each key appends to what the field shows, the way a keyboard does: the field's own rewrites
    // between keystrokes are part of what these tests have to survive.
    const type = (keys: string) => {
      for (const key of keys) fireEvent.change(input, { target: { value: input.value + key } });
    };
    const paste = (value: string) => fireEvent.change(input, { target: { value } });
    return { input, onChange, type, paste };
  };

  it("keeps a grouped amount as thousands", () => {
    const { input, onChange, type } = renderAmount("krw");
    type("7,900");

    expect(input.value).toBe("7900");
    expect(onChange).toHaveBeenLastCalledWith(790_000);
  });

  it.each(["7,900 ", "7,900₩"])("keeps a pasted grouped amount with a suffix (%j) as thousands", (pasted) => {
    const { input, onChange, paste } = renderAmount("krw");
    paste(pasted);

    expect(input.value).toBe("7900");
    expect(onChange).toHaveBeenLastCalledWith(790_000);
  });

  it("reads a comma before two digits as a decimal point", () => {
    const { input, onChange, type } = renderAmount("eur");
    type("7,90");

    expect(input.value).toBe("7,90");
    expect(onChange).toHaveBeenLastCalledWith(790);
  });

  it("groups a decimal amount", () => {
    const { input, onChange, type } = renderAmount("usd");
    type("12,345.67");

    // The field renders without grouping separators, so the comma the parser read as thousands is
    // gone from the display by the time the fractional keys arrive.
    expect(input.value).toBe("12345.67");
    expect(onChange).toHaveBeenLastCalledWith(1_234_567);
  });

  it.each(["-1.00", "-1,50", "-1,5", "-1,", "-1."])("reports a clamped zero for a negative amount (%j)", (pasted) => {
    const { input, onChange, paste } = renderAmount("usd");
    paste(pasted);

    expect(input.value).toBe("0");
    expect(onChange).toHaveBeenLastCalledWith(0);
  });

  it("waits for an IME composition to end before settling the amount", () => {
    const { input, onChange, type } = renderAmount("krw");
    fireEvent.compositionStart(input);
    type("7,900");

    expect(input.value).toBe("7,900");
    fireEvent.compositionEnd(input);
    expect(input.value).toBe("7900");
    expect(onChange).toHaveBeenLastCalledWith(790_000);
  });

  it("caps the fraction at two digits", () => {
    const { input, onChange, type } = renderAmount("usd");
    type("1.999");

    expect(input.value).toBe("1.99");
    expect(onChange).toHaveBeenLastCalledWith(199);
  });

  // Once the fraction is complete neither separator can change meaning, so the grouping comma goes.
  it("settles a typed amount that carries both separators", () => {
    const { input, onChange, type } = renderAmount("usd");
    type("-1234,.439");

    expect(input.value).toBe("1234.43");
    expect(onChange).toHaveBeenLastCalledWith(123_443);
  });
});
