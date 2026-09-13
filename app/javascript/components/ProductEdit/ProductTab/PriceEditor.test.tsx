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
