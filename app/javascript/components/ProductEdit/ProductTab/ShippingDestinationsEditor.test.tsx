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

    const removeButtons = screen.getAllByRole("button", { name: "Remove excluded country" });
    const secondRemoveButton = removeButtons[1];
    if (!secondRemoveButton) throw new Error("expected two remove-exclusion buttons");
    fireEvent.click(secondRemoveButton);

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

    const canadaOptions = screen.getAllByRole("option", { name: "Canada" });
    const disabledOptions = canadaOptions.filter((option) => option.hasAttribute("disabled"));

    expect(disabledOptions).toHaveLength(1);
    expect(disabledOptions[0]).toHaveProperty("selected", false);
  });

  it("changes the country of one exclusion row in place", () => {
    const onExcludedCountryCodesChange = vi.fn();
    render(
      <ShippingDestinationsEditor
        shippingDestinations={[destination]}
        onChange={vi.fn()}
        excludedCountryCodes={["US", "CA"]}
        onExcludedCountryCodesChange={onExcludedCountryCodesChange}
      />,
    );

    const [firstSelect] = screen.getAllByLabelText("Excluded country");
    if (!firstSelect) throw new Error("expected an exclusion select");
    fireEvent.change(firstSelect, { target: { value: "DE" } });

    expect(onExcludedCountryCodesChange).toHaveBeenCalledWith(["DE", "CA"]);
  });

  it("stops offering to add once every country is excluded", () => {
    render(
      <ShippingDestinationsEditor
        shippingDestinations={[destination]}
        onChange={vi.fn()}
        excludedCountryCodes={["US", "DE", "CA"]}
        onExcludedCountryCodesChange={vi.fn()}
      />,
    );

    expect(screen.getAllByRole("button", { name: "Remove excluded country" })).toHaveLength(3);
    expect(screen.queryByRole("button", { name: "Add excluded country" })).toBeNull();
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
