// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PriceEditor } from "$app/components/ProductEdit/ProductTab/PriceEditor";

afterEach(cleanup);

const noop = () => undefined;

const renderEditor = (
  overrides: Partial<React.ComponentProps<typeof PriceEditor>> & {
    isPWYW: boolean;
    setIsPWYW: (isPWYW: boolean) => void;
  },
) =>
  render(
    <PriceEditor
      priceCents={0}
      suggestedPriceCents={null}
      setPriceCents={noop}
      setSuggestedPriceCents={noop}
      currencyType="usd"
      eligibleForInstallmentPlans={false}
      allowInstallmentPlan={false}
      numberOfInstallments={null}
      onAllowInstallmentPlanChange={noop}
      onNumberOfInstallmentsChange={noop}
      {...overrides}
    />,
  );

describe("PriceEditor Amount field", () => {
  // The field is backed by `PriceInput`, which reads a comma before three digits as thousands
  // grouping (the same reading `clean_price` applies on the new-product page), so 7,900 typed
  // here is $7,900, not $7.90.
  it("reads 7,900 as $7,900 and shows an example amount", () => {
    const setPriceCents = vi.fn();
    renderEditor({ isPWYW: false, setIsPWYW: noop, setPriceCents, priceCents: 0 });

    fireEvent.change(screen.getByLabelText("Amount"), { target: { value: "7,900" } });

    expect(setPriceCents).toHaveBeenCalledWith(790000);
    fireEvent.change(screen.getByLabelText("Amount"), { target: { value: "7,90" } });
    expect(setPriceCents).toHaveBeenLastCalledWith(790);
    expect(screen.getByText("Enter an amount like 7900 or 9.99.")).toBeTruthy();
  });

  it("reads 7,900 as ¥7,900 and asks for a whole amount in a currency without minor units", () => {
    const setPriceCents = vi.fn();
    renderEditor({ isPWYW: false, setIsPWYW: noop, setPriceCents, priceCents: 0, currencyType: "jpy" });

    fireEvent.change(screen.getByLabelText("Amount"), { target: { value: "7,900" } });

    expect(setPriceCents).toHaveBeenCalledWith(7900);
    expect(screen.getByText("Enter a whole amount like 7900.")).toBeTruthy();
  });
});

describe("PriceEditor PWYW toggle", () => {
  it("leaves PWYW editable on a $0-base product with paid variants", () => {
    const setIsPWYW = vi.fn();
    renderEditor({ isPWYW: true, setIsPWYW, hasPaidVariants: true, priceCents: 0 });

    const toggle = screen.getByRole("switch");
    expect(toggle).toHaveProperty("disabled", false);
    expect(toggle).toHaveProperty("checked", true);
    expect(screen.queryByText("Pay what you want isn't available on products with paid pricing options.")).toBeNull();
    expect(setIsPWYW).not.toHaveBeenCalled();
  });

  it("turns PWYW on from the switch on a $0-base product with paid variants", () => {
    const setIsPWYW = vi.fn();
    renderEditor({ isPWYW: false, setIsPWYW, hasPaidVariants: true, priceCents: 0 });

    const toggle = screen.getByRole("switch");
    expect(toggle).toHaveProperty("checked", false);
    fireEvent.click(toggle);
    expect(setIsPWYW).toHaveBeenCalledWith(true);
  });

  it("keeps a free product without variants locked on to PWYW", () => {
    const setIsPWYW = vi.fn();
    renderEditor({ isPWYW: true, setIsPWYW, hasPaidVariants: false, priceCents: 0 });

    const toggle = screen.getByRole("switch");
    expect(toggle).toHaveProperty("disabled", true);
    expect(toggle).toHaveProperty("checked", true);
    expect(screen.getByText("Free products require a pay what they want price.")).toBeTruthy();
    expect(setIsPWYW).not.toHaveBeenCalled();
  });

  it("leaves PWYW editable on a paid product that also has paid variants", () => {
    const setIsPWYW = vi.fn();
    renderEditor({ isPWYW: false, setIsPWYW, hasPaidVariants: true, priceCents: 1500 });

    expect(screen.getByRole("switch")).toHaveProperty("disabled", false);
    expect(setIsPWYW).not.toHaveBeenCalled();
  });

  it("shows PWYW as locked on when a $0 product loses its last paid option", () => {
    const setIsPWYW = vi.fn();
    const view = renderEditor({ isPWYW: false, setIsPWYW, hasPaidVariants: true, priceCents: 0 });

    view.rerender(
      <PriceEditor
        priceCents={0}
        suggestedPriceCents={null}
        setPriceCents={noop}
        setSuggestedPriceCents={noop}
        currencyType="usd"
        eligibleForInstallmentPlans={false}
        allowInstallmentPlan={false}
        numberOfInstallments={null}
        onAllowInstallmentPlanChange={noop}
        onNumberOfInstallmentsChange={noop}
        isPWYW={false}
        setIsPWYW={setIsPWYW}
        hasPaidVariants={false}
      />,
    );

    const toggle = screen.getByRole("switch");
    expect(toggle).toHaveProperty("disabled", true);
    expect(toggle).toHaveProperty("checked", true);
    expect(setIsPWYW).not.toHaveBeenCalled();
  });
});

describe("PriceEditor installments toggle", () => {
  it("says why installments are unavailable while pay what you want is on", () => {
    renderEditor({
      isPWYW: true,
      setIsPWYW: noop,
      eligibleForInstallmentPlans: true,
      maxEffectivePriceCents: 1500,
      hasPaidVariants: true,
    });

    const toggle = screen.getByRole("switch", { name: /installments/iu });
    expect(toggle).toHaveProperty("disabled", true);
    const note = screen.getByText("Installments aren't available with pay what you want.");
    expect(toggle.getAttribute("aria-describedby")).toBe(note.id);
  });

  it("leaves installments selectable and unexplained when pay what you want is off", () => {
    renderEditor({
      isPWYW: false,
      setIsPWYW: noop,
      eligibleForInstallmentPlans: true,
      maxEffectivePriceCents: 1500,
      hasPaidVariants: true,
      priceCents: 1500,
    });

    expect(screen.getByRole("switch", { name: /installments/iu })).toHaveProperty("disabled", false);
    expect(screen.queryByText("Installments aren't available with pay what you want.")).toBeNull();
    expect(screen.getByRole("switch", { name: /installments/iu }).getAttribute("aria-describedby")).toBeNull();
  });
});

describe("PriceEditor amount hint", () => {
  const amountDescription = () => {
    const ids = screen.getByLabelText("Amount").getAttribute("aria-describedby")?.split(" ") ?? [];
    return ids.map((id) => document.getElementById(id)?.textContent).join(" ");
  };

  it("shows an example amount with decimals", () => {
    renderEditor({ isPWYW: false, setIsPWYW: noop, priceCents: 1500, currencyType: "usd" });

    expect(amountDescription()).toBe("Enter an amount like 7900 or 9.99.");
  });

  it("asks for a whole amount in a currency without minor units", () => {
    renderEditor({ isPWYW: false, setIsPWYW: noop, priceCents: 1500, currencyType: "jpy" });

    expect(amountDescription()).toBe("Enter a whole amount like 7900.");
  });
});
