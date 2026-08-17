// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { getRemainingCallAvailabilities } from "$app/data/call_availabilities";

import {
  ConfigurationSelector,
  type PriceSelection,
  type Product,
} from "$app/components/Product/ConfigurationSelector";

vi.mock("$app/data/call_availabilities", () => ({
  getRemainingCallAvailabilities: vi.fn(),
}));

afterEach(cleanup);

const durationOption = {
  id: "duration-30",
  name: "30 minutes",
  quantity_left: null,
  description: "",
  price_difference_cents: 0,
  recurrence_price_values: null,
  is_pwyw: false,
  duration_in_minutes: 30,
};

const callProduct: Product = {
  permalink: "songwriting-consultation",
  rental: null,
  options: [durationOption],
  currency_code: "usd",
  price_cents: 7499,
  installment_plan: null,
  is_tiered_membership: false,
  is_legacy_subscription: false,
  is_quantity_enabled: false,
  is_multiseat_license: false,
  quantity_remaining: null,
  recurrences: null,
  pwyw: null,
  ppp_details: null,
  native_type: "call",
};

const initialSelection: PriceSelection = {
  rent: false,
  optionId: durationOption.id,
  price: { error: false, value: null },
  quantity: 1,
  recurrence: null,
  callStartTime: null,
  payInInstallments: false,
};

const octoberFirstAfternoon = {
  start_time: new Date(2024, 9, 1, 13, 0, 0),
  end_time: new Date(2024, 9, 1, 15, 0, 0),
};
const octoberSecondAfternoon = {
  start_time: new Date(2024, 9, 2, 13, 0, 0),
  end_time: new Date(2024, 9, 2, 15, 0, 0),
};

const renderCallSelector = () => {
  const selections: PriceSelection[] = [];
  const Harness = () => {
    const [selection, setSelection] = React.useState(initialSelection);
    return (
      <ConfigurationSelector
        product={callProduct}
        selection={selection}
        setSelection={(update) => {
          setSelection((prev) => {
            const next = typeof update === "function" ? update(prev) : update;
            selections.push(next);
            return next;
          });
        }}
        discount={null}
      />
    );
  };
  render(<Harness />);
  return { selections };
};

describe("CallDateAndTimeSelector", () => {
  it("exposes a labeled date select and native time radios a screen reader can operate", async () => {
    vi.mocked(getRemainingCallAvailabilities).mockResolvedValue([octoberFirstAfternoon, octoberSecondAfternoon]);

    const { selections } = renderCallSelector();

    const dateSelect = await screen.findByLabelText("Date");
    if (!(dateSelect instanceof HTMLSelectElement)) throw new Error("expected a native date <select>");
    expect(dateSelect.disabled).toBe(false);
    expect(Array.from(dateSelect.options).map((option) => option.text)).toEqual([
      "Tuesday, October 1, 2024",
      "Wednesday, October 2, 2024",
    ]);

    await waitFor(() => expect(selections.at(-1)?.callStartTime).toBe(octoberFirstAfternoon.start_time.toISOString()));

    const firstTime = screen.getByRole("radio", { name: "01:00 PM" });
    if (!(firstTime instanceof HTMLInputElement)) throw new Error("expected a native time radio");
    expect(firstTime.type).toBe("radio");
    expect(firstTime.checked).toBe(true);

    fireEvent.change(dateSelect, { target: { value: "2024-10-02" } });
    await waitFor(() => expect(selections.at(-1)?.callStartTime).toBe(octoberSecondAfternoon.start_time.toISOString()));

    fireEvent.click(screen.getByRole("radio", { name: "01:30 PM" }));
    await waitFor(() => expect(selections.at(-1)?.callStartTime).toBe(new Date(2024, 9, 2, 13, 30, 0).toISOString()));

    const confirmation = screen.getByText("Wednesday, October 2 at 01:30 PM");
    expect(confirmation.closest("[aria-live]")?.getAttribute("aria-live")).toBe("polite");
  });
});
