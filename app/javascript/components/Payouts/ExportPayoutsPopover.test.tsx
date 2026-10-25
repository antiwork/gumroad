// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { ResponseError } from "$app/utils/request";

import { ExportPayoutsPopover } from "$app/components/Payouts/ExportPayoutsPopover";

const mocks = vi.hoisted(() => ({ get: vi.fn(), export: vi.fn() }));
vi.mock("$app/data/balance", () => ({ getExportablePayouts: mocks.get, exportPayouts: mocks.export }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
const year = new Date().getFullYear();
const data = (selected = year, payouts = [{ id: "payout-1", date_formatted: "October 16" }]) => ({
  selected_year: selected,
  years_with_payouts: [year, year - 1],
  payouts_in_selected_year: payouts,
});
beforeEach(() => {
  mocks.get.mockReset();
  mocks.export.mockReset().mockResolvedValue(undefined);
});
afterEach(cleanup);
const open = () => {
  render(<ExportPayoutsPopover />);
  fireEvent.click(screen.getByRole("button", { name: "Export all" }));
};

describe("payout export loading", () => {
  it("shows an error and releases the loading controls after a failed request", async () => {
    mocks.get.mockRejectedValueOnce(new ResponseError());
    open();
    expect(await screen.findByRole("alert")).not.toBeNull();
    expect(screen.queryByRole("progressbar")).toBeNull();
    expect(screen.getByRole<HTMLSelectElement>("combobox", { name: "Filter by year" }).disabled).toBe(false);
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Download" }).disabled).toBe(true);
    expect(screen.getByRole("button", { name: "Try again" })).not.toBeNull();
  });

  it("retries the selected year and recovers without reopening the popover", async () => {
    mocks.get.mockRejectedValueOnce(new ResponseError()).mockResolvedValueOnce(data());
    open();
    fireEvent.click(await screen.findByRole("button", { name: "Try again" }));
    expect(await screen.findByText("October 16")).not.toBeNull();
    expect(mocks.get.mock.calls).toEqual([[year], [year]]);
    expect(screen.queryByRole("alert")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Select all" }));
    fireEvent.click(screen.getByRole("button", { name: "Download" }));
    await waitFor(() => expect(mocks.export).toHaveBeenCalledWith(["payout-1"]));
  });

  it("clears stale rows and selection when another year's request fails", async () => {
    mocks.get
      .mockResolvedValueOnce(data())
      .mockRejectedValueOnce(new ResponseError())
      .mockResolvedValueOnce(data(year - 1, [{ id: "older", date_formatted: "Previous year payout" }]));
    open();
    await screen.findByText("October 16");
    fireEvent.click(screen.getByRole("button", { name: "Select all" }));
    fireEvent.change(screen.getByRole("combobox", { name: "Filter by year" }), { target: { value: String(year - 1) } });
    const retry = await screen.findByRole("button", { name: "Try again" });
    expect(screen.queryByText("October 16")).toBeNull();
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Download" }).disabled).toBe(true);
    fireEvent.click(retry);
    expect(await screen.findByText("Previous year payout")).not.toBeNull();
    expect(screen.queryByText("October 16")).toBeNull();
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Download" }).disabled).toBe(true);
    expect(mocks.get.mock.calls).toEqual([[year], [year - 1], [year - 1]]);
  });

  it("keeps a repeated failure retryable", async () => {
    mocks.get.mockRejectedValue(new ResponseError());
    open();
    fireEvent.click(await screen.findByRole("button", { name: "Try again" }));
    expect(await screen.findByRole("button", { name: "Try again" })).not.toBeNull();
    expect(screen.queryByRole("progressbar")).toBeNull();
    expect(mocks.get).toHaveBeenCalledTimes(2);
  });

  it("disables duplicate retries while the replacement request is pending", async () => {
    let resolve: ((value: ReturnType<typeof data>) => void) | undefined;
    mocks.get.mockRejectedValueOnce(new ResponseError()).mockImplementationOnce(
      () =>
        new Promise((r) => {
          resolve = r;
        }),
    );
    open();
    const retry = await screen.findByRole("button", { name: "Try again" });
    fireEvent.click(retry);
    fireEvent.click(retry);
    expect(mocks.get).toHaveBeenCalledTimes(2);
    expect(screen.getByRole<HTMLSelectElement>("combobox", { name: "Filter by year" }).disabled).toBe(true);
    await act(async () => {
      resolve?.(data());
    });
    expect(await screen.findByText("October 16")).not.toBeNull();
  });

  it("distinguishes an empty successful year from a load failure", async () => {
    mocks.get.mockResolvedValueOnce(data(year, []));
    open();
    expect(await screen.findByText("No payouts found for this year.")).not.toBeNull();
    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.queryByRole("button", { name: "Try again" })).toBeNull();
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Download" }).disabled).toBe(true);
  });
});
