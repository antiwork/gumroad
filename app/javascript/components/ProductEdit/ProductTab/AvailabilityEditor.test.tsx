// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { assertDefined } from "$app/utils/assert";

import { AvailabilityEditor } from "$app/components/ProductEdit/ProductTab/AvailabilityEditor";
import type { Availability } from "$app/components/ProductEdit/state";

const seller = vi.hoisted(() => ({ timeZone: { name: "UTC" } }));
vi.mock("$app/components/CurrentSeller", () => ({ useCurrentSeller: () => seller }));

afterEach(() => {
  cleanup();
  seller.timeZone.name = "UTC";
});

const renderEditor = (initial: Availability[]) => {
  const changed = vi.fn();
  const Harness = () => {
    const [availabilities, setAvailabilities] = React.useState(initial);
    return (
      <AvailabilityEditor
        availabilities={availabilities}
        onChange={(next) => {
          changed(next);
          setAvailabilities(next);
        }}
      />
    );
  };
  render(<Harness />);
  return changed;
};

describe("AvailabilityEditor day changes", () => {
  it("moves every disjoint interval under one Date control and leaves another day unchanged", () => {
    const neighbor = { id: "neighbor", start_time: "2026-10-18T12:00:00Z", end_time: "2026-10-18T13:00:00Z" };
    const changed = renderEditor([
      { id: "morning", start_time: "2026-10-14T09:00:00Z", end_time: "2026-10-14T10:00:00Z" },
      { id: "afternoon", start_time: "2026-10-14T14:00:00Z", end_time: "2026-10-14T15:00:00Z", newlyAdded: true },
      neighbor,
    ]);
    fireEvent.blur(assertDefined(screen.getAllByLabelText("Date")[0]), { target: { value: "2026-10-16" } });
    expect(changed).toHaveBeenLastCalledWith([
      { id: "morning", start_time: "2026-10-16T09:00:00.000Z", end_time: "2026-10-16T10:00:00.000Z" },
      {
        id: "afternoon",
        start_time: "2026-10-16T14:00:00.000Z",
        end_time: "2026-10-16T15:00:00.000Z",
        newlyAdded: true,
      },
      neighbor,
    ]);
    expect(screen.getAllByLabelText("Date")).toHaveLength(2);
    expect(screen.getAllByLabelText<HTMLInputElement>("Date").map(({ value }) => value)).toEqual([
      "2026-10-16",
      "2026-10-18",
    ]);
  });

  it("combines the moved day with an existing day without changing its intervals", () => {
    const destination = { id: "destination", start_time: "2026-10-16T12:00:00Z", end_time: "2026-10-16T13:00:00Z" };
    const changed = renderEditor([
      { id: "morning", start_time: "2026-10-14T09:00:00Z", end_time: "2026-10-14T10:00:00Z" },
      { id: "afternoon", start_time: "2026-10-14T14:00:00Z", end_time: "2026-10-14T15:00:00Z" },
      destination,
    ]);
    fireEvent.blur(assertDefined(screen.getAllByLabelText("Date")[0]), { target: { value: "2026-10-16" } });
    expect(changed).toHaveBeenLastCalledWith([
      { id: "morning", start_time: "2026-10-16T09:00:00.000Z", end_time: "2026-10-16T10:00:00.000Z" },
      { id: "afternoon", start_time: "2026-10-16T14:00:00.000Z", end_time: "2026-10-16T15:00:00.000Z" },
      destination,
    ]);
    expect(screen.getAllByLabelText("Date")).toHaveLength(1);
    expect(screen.getAllByLabelText<HTMLInputElement>("From").map(({ value }) => value)).toEqual([
      "09:00",
      "12:00",
      "14:00",
    ]);
  });

  it.each([
    {
      start: "2026-10-14T23:00:00Z",
      end: "2026-10-15T00:00:00Z",
      date: "2026-10-16",
      newStart: "2026-10-16T23:00:00.000Z",
      newEnd: "2026-10-17T00:00:00.000Z",
    },
    {
      start: "2026-12-31T23:00:00Z",
      end: "2027-01-01T00:00:00Z",
      date: "2027-01-01",
      newStart: "2027-01-01T23:00:00.000Z",
      newEnd: "2027-01-02T00:00:00.000Z",
    },
    {
      start: "2028-02-28T23:00:00Z",
      end: "2028-02-29T00:00:00Z",
      date: "2028-02-29",
      newStart: "2028-02-29T23:00:00.000Z",
      newEnd: "2028-03-01T00:00:00.000Z",
    },
  ])(
    "retains the next-day endpoint when moving an overnight interval to $date",
    ({ start, end, date, newStart, newEnd }) => {
      const changed = renderEditor([{ id: "overnight", start_time: start, end_time: end }]);
      fireEvent.blur(screen.getByLabelText("Date"), { target: { value: date } });
      expect(changed).toHaveBeenLastCalledWith([{ id: "overnight", start_time: newStart, end_time: newEnd }]);
      expect(screen.getByLabelText<HTMLInputElement>("From").value).toBe("23:00");
      expect(screen.getByLabelText<HTMLInputElement>("To").value).toBe("00:00");
    },
  );

  it("moves an overnight interval by the seller's local date rather than its UTC date", () => {
    seller.timeZone.name = "America/Los_Angeles";
    const changed = renderEditor([
      { id: "overnight", start_time: "2026-10-15T06:00:00Z", end_time: "2026-10-15T07:00:00Z" },
    ]);
    expect(screen.getByLabelText<HTMLInputElement>("Date").value).toBe("2026-10-14");
    fireEvent.blur(screen.getByLabelText("Date"), { target: { value: "2026-10-16" } });
    expect(changed).toHaveBeenLastCalledWith([
      { id: "overnight", start_time: "2026-10-17T06:00:00.000Z", end_time: "2026-10-17T07:00:00.000Z" },
    ]);
  });

  it("retains seller-local clock times across a daylight-saving date shift", () => {
    seller.timeZone.name = "America/Los_Angeles";
    const changed = renderEditor([
      { id: "daytime", start_time: "2026-03-07T18:00:00Z", end_time: "2026-03-07T19:00:00Z" },
    ]);
    fireEvent.blur(screen.getByLabelText("Date"), { target: { value: "2026-03-08" } });
    expect(changed).toHaveBeenLastCalledWith([
      { id: "daytime", start_time: "2026-03-08T17:00:00.000Z", end_time: "2026-03-08T18:00:00.000Z" },
    ]);
    expect(screen.getByLabelText<HTMLInputElement>("From").value).toBe("10:00");
    expect(screen.getByLabelText<HTMLInputElement>("To").value).toBe("11:00");
  });

  it("retains exact ambiguous instants when the grouped date did not change", () => {
    seller.timeZone.name = "America/Los_Angeles";
    const intervals = [
      { id: "earlier", start_time: "2026-11-01T08:00:00.000Z", end_time: "2026-11-01T08:15:00.000Z" },
      { id: "later", start_time: "2026-11-01T09:30:00.000Z", end_time: "2026-11-01T10:30:00.000Z" },
    ];
    const changed = renderEditor(intervals);
    fireEvent.blur(screen.getByLabelText("Date"), { target: { value: "2026-11-01" } });
    expect(changed.mock.lastCall?.[0] ?? intervals).toEqual(intervals);
  });

  it("retains seller clock times when the browser timezone skips that hour on the new date", () => {
    const changed = renderEditor([
      { id: "early", start_time: "2026-03-07T02:30:00Z", end_time: "2026-03-07T03:30:00Z" },
    ]);
    fireEvent.blur(screen.getByLabelText("Date"), { target: { value: "2026-03-08" } });
    expect(changed).toHaveBeenLastCalledWith([
      { id: "early", start_time: "2026-03-08T02:30:00.000Z", end_time: "2026-03-08T03:30:00.000Z" },
    ]);
  });

  it("renders the shifted seller clocks independently of the browser's daylight-saving gap", () => {
    renderEditor([{ id: "early", start_time: "2026-03-07T02:30:00Z", end_time: "2026-03-07T03:30:00Z" }]);
    fireEvent.blur(screen.getByLabelText("Date"), { target: { value: "2026-03-08" } });
    expect(screen.getByLabelText<HTMLInputElement>("From").value).toBe("02:30");
    expect(screen.getByLabelText<HTMLInputElement>("To").value).toBe("03:30");
  });

  it("keeps overnight seller clocks across DST while respecting the new day's offset", () => {
    seller.timeZone.name = "America/Los_Angeles";
    const changed = renderEditor([
      { id: "night", start_time: "2026-03-07T07:00:00Z", end_time: "2026-03-07T11:00:00Z" },
    ]);
    fireEvent.blur(screen.getByLabelText("Date"), { target: { value: "2026-03-07" } });
    expect(changed).toHaveBeenLastCalledWith([
      { id: "night", start_time: "2026-03-08T07:00:00.000Z", end_time: "2026-03-08T10:00:00.000Z" },
    ]);
    expect(screen.getByLabelText<HTMLInputElement>("From").value).toBe("23:00");
    expect(screen.getByLabelText<HTMLInputElement>("To").value).toBe("03:00");
  });

  it("edits a seller-valid time without normalizing it through the browser timezone", () => {
    const changed = renderEditor([
      { id: "early", start_time: "2026-03-08T02:30:00Z", end_time: "2026-03-08T03:30:00Z" },
    ]);
    expect(screen.getByLabelText<HTMLInputElement>("From").value).toBe("02:30");
    fireEvent.change(screen.getByLabelText("From"), { target: { value: "02:45" } });
    expect(changed).toHaveBeenLastCalledWith([
      { id: "early", start_time: "2026-03-08T02:45:00.000Z", end_time: "2026-03-08T03:30:00Z" },
    ]);
    expect(screen.getByLabelText<HTMLInputElement>("From").value).toBe("02:45");
  });

  it("adds overnight hours from the seller's endpoint date", () => {
    seller.timeZone.name = "America/Los_Angeles";
    const existing = { id: "evening", start_time: "2026-10-15T05:00:00Z", end_time: "2026-10-15T06:00:00Z" };
    const changed = renderEditor([existing]);
    fireEvent.click(screen.getByRole("button", { name: "Add hours" }));
    expect(changed).toHaveBeenLastCalledWith([
      existing,
      expect.objectContaining({
        start_time: "2026-10-15T06:00:00.000Z",
        end_time: "2026-10-15T07:00:00.000Z",
        newlyAdded: true,
      }),
    ]);
    expect(screen.getAllByLabelText<HTMLInputElement>("From").map(({ value }) => value)).toEqual(["22:00", "23:00"]);
    expect(screen.getAllByLabelText<HTMLInputElement>("To").map(({ value }) => value)).toEqual(["23:00", "00:00"]);
    expect(screen.getAllByLabelText("Date")).toHaveLength(1);
  });

  it("starts a new day after the seller's last local date, even when its UTC date differs", () => {
    seller.timeZone.name = "America/Los_Angeles";
    const existing = { id: "evening", start_time: "2026-10-15T05:00:00Z", end_time: "2026-10-15T06:00:00Z" };
    const changed = renderEditor([existing]);
    fireEvent.click(screen.getByRole("button", { name: "Add day of availability" }));
    expect(changed).toHaveBeenLastCalledWith([
      existing,
      expect.objectContaining({
        start_time: "2026-10-15T16:00:00.000Z",
        end_time: "2026-10-16T00:00:00.000Z",
        newlyAdded: true,
      }),
    ]);
    expect(screen.getAllByLabelText<HTMLInputElement>("Date").map(({ value }) => value)).toEqual([
      "2026-10-14",
      "2026-10-15",
    ]);
  });

  it("leaves intervals intact when the Date input is cleared", () => {
    const changed = renderEditor([
      { id: "morning", start_time: "2026-10-14T09:00:00Z", end_time: "2026-10-14T10:00:00Z" },
    ]);
    fireEvent.blur(screen.getByLabelText("Date"), { target: { value: "" } });
    expect(changed).not.toHaveBeenCalled();
  });
});
