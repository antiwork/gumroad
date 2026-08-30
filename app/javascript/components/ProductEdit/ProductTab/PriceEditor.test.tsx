// @vitest-environment happy-dom
import { cleanup, render, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PriceEditor } from "$app/components/ProductEdit/ProductTab/PriceEditor";

vi.mock("$app/components/ui/Alert", () => ({
  Alert: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
}));

afterEach(cleanup);

const renderEditor = (overrides: Partial<React.ComponentProps<typeof PriceEditor>> = {}) => {
  const setIsPWYW = vi.fn();
  const view = render(
    <PriceEditor
      priceCents={0}
      suggestedPriceCents={null}
      isPWYW={false}
      setPriceCents={() => {}}
      setSuggestedPriceCents={() => {}}
      setIsPWYW={setIsPWYW}
      currencyType="usd"
      eligibleForInstallmentPlans={false}
      allowInstallmentPlan={false}
      numberOfInstallments={null}
      onAllowInstallmentPlanChange={() => {}}
      onNumberOfInstallmentsChange={() => {}}
      {...overrides}
    />,
  );
  return { ...view, setIsPWYW };
};

const pwywSwitch = (view: ReturnType<typeof render>): HTMLInputElement => {
  const toggle = view.getByRole("switch");
  if (!(toggle instanceof HTMLInputElement)) throw new Error("expected checkbox");
  return toggle;
};

describe("PriceEditor pay what you want toggle", () => {
  it("forces pay what you want on for a $0 product with no paid options", () => {
    const { setIsPWYW, ...view } = renderEditor({ isPWYW: true, hasPaidVariants: false });
    const toggle = pwywSwitch(view);

    expect(toggle.checked).toBe(true);
    expect(toggle.disabled).toBe(true);
    expect(view.getByText("Free products require a pay what they want price.")).toBeTruthy();
    expect(setIsPWYW).not.toHaveBeenCalled();
  });

  it("disables pay what you want on a $0 product with paid pricing options", async () => {
    const { setIsPWYW, ...view } = renderEditor({ isPWYW: true, hasPaidVariants: true });
    const toggle = pwywSwitch(view);

    expect(toggle.checked).toBe(false);
    expect(toggle.disabled).toBe(true);
    expect(view.getByText("Pay what you want isn't available on products with paid pricing options.")).toBeTruthy();
    expect(view.queryByText("Free products require a pay what they want price.")).toBeNull();
    await waitFor(() => expect(setIsPWYW).toHaveBeenCalledWith(false));
  });

  it("leaves the toggle enabled on a paid product that also has paid options", () => {
    const { setIsPWYW, ...view } = renderEditor({
      priceCents: 1000,
      isPWYW: false,
      hasPaidVariants: true,
    });
    const toggle = pwywSwitch(view);

    expect(toggle.disabled).toBe(false);
    expect(view.queryByText("Pay what you want isn't available on products with paid pricing options.")).toBeNull();
    expect(setIsPWYW).not.toHaveBeenCalled();
  });
});
