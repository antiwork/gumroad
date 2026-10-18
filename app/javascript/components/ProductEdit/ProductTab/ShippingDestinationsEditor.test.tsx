// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { ShippingDestinationsEditor } from "$app/components/ProductEdit/ProductTab/ShippingDestinationsEditor";

vi.mock("$app/components/WithTooltip", () => ({
  WithTooltip: ({ children }: { children?: React.ReactNode }) => <span>{children}</span>,
}));

vi.mock("$app/components/ProductEdit/state", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/components/ProductEdit/state")>();
  return {
    ...actual,
    useProductEditContext: () => ({
      availableCountries: [
        { code: "US", name: "United States" },
        { code: "ELSEWHERE", name: "Elsewhere" },
        { code: "DE", name: "Germany" },
        { code: "CA", name: "Canada" },
      ],
      currencyType: "usd",
    }),
  };
});

afterEach(() => {
  cleanup();
});

const destination = { country_code: "ELSEWHERE", one_item_rate_cents: 0, multiple_items_rate_cents: 0 };

describe("ShippingDestinationsEditor exclusions", () => {
  it("offers only concrete countries and adds the first unused one", () => {
    const onExcludedCountryCodesChange = vi.fn();
    render(
      <ShippingDestinationsEditor
        shippingDestinations={[destination]}
        onChange={vi.fn()}
        excludedCountryCodes={["US"]}
        onExcludedCountryCodesChange={onExcludedCountryCodesChange}
      />,
    );

    expect(screen.getByText("Do not ship to")).toBeTruthy();

    const excludedCountrySelect = within(screen.getByLabelText("Excluded country"));
    expect(excludedCountrySelect.getByRole("option", { name: "United States" })).toBeTruthy();
    expect(excludedCountrySelect.queryByRole("option", { name: "Elsewhere" })).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: "Add excluded country" }));

    expect(onExcludedCountryCodesChange).toHaveBeenCalledWith(["US", "DE"]);
  });

  it("removes an exclusion", () => {
    const onExcludedCountryCodesChange = vi.fn();
    render(
      <ShippingDestinationsEditor
        shippingDestinations={[destination]}
        onChange={vi.fn()}
        excludedCountryCodes={["US", "CA"]}
        onExcludedCountryCodesChange={onExcludedCountryCodesChange}
      />,
    );

    fireEvent.click(screen.getAllByRole("button", { name: "Remove excluded country" })[1]);

    expect(onExcludedCountryCodesChange).toHaveBeenCalledWith(["US"]);
  });

  it("disables a country another exclusion row already uses", () => {
    render(
      <ShippingDestinationsEditor
        shippingDestinations={[destination]}
        onChange={vi.fn()}
        excludedCountryCodes={["US", "CA"]}
        onExcludedCountryCodesChange={vi.fn()}
      />,
    );

    const canadaOptions = screen.getAllByRole("option", { name: "Canada" }) as HTMLOptionElement[];
    const disabled = canadaOptions.filter((option) => option.disabled);

    expect(disabled).toHaveLength(1);
    expect(disabled[0].selected).toBe(false);
  });

  it("hides the exclusion card when the product has no destinations", () => {
    render(
      <ShippingDestinationsEditor
        shippingDestinations={[]}
        onChange={vi.fn()}
        excludedCountryCodes={[]}
        onExcludedCountryCodesChange={vi.fn()}
      />,
    );

    expect(screen.queryByText("Do not ship to")).toBeNull();
  });
});
