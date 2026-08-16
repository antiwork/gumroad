// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { FooterCurrencySelector } from "$app/components/FooterCurrencySelector";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  document.cookie = "gumroad_buyer_currency=; path=/; max-age=0";
  window.history.replaceState({}, "", "/");
});

describe("FooterCurrencySelector", () => {
  it("defaults to the detected currency and writes the cookie on change", () => {
    const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});
    render(<FooterCurrencySelector detectedCurrency="usd" />);

    const select = screen.getByLabelText<HTMLSelectElement>("Currency");
    expect(select.value).toBe("usd");
    expect(screen.getByRole("option", { name: "$ (US Dollars) — detected" })).toBeTruthy();
    // The detected currency is one option, not a phantom entry alongside the real one.
    expect(screen.queryByRole("option", { name: "$ (US Dollars)" })).toBeNull();

    fireEvent.change(select, { target: { value: "gbp" } });

    expect(document.cookie).toContain("gumroad_buyer_currency=gbp");
    expect(assign).toHaveBeenCalled();
  });

  it("falls back to USD when detection returns nothing", () => {
    render(<FooterCurrencySelector />);

    expect(screen.getByLabelText<HTMLSelectElement>("Currency").value).toBe("usd");
  });

  it("disables itself once the reload is under way", () => {
    vi.spyOn(window.location, "assign").mockImplementation(() => {});
    render(<FooterCurrencySelector detectedCurrency="usd" />);

    const select = screen.getByLabelText<HTMLSelectElement>("Currency");
    expect(select.disabled).toBe(false);

    fireEvent.change(select, { target: { value: "gbp" } });

    expect(select.disabled).toBe(true);
  });

  it("strips a ?currency= param so it cannot override the new selection", () => {
    const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});
    window.history.replaceState({}, "", "/l/demo?currency=eur&foo=bar");
    render(<FooterCurrencySelector />);

    // The URL param wins on read, so the selector starts at eur.
    const select = screen.getByLabelText<HTMLSelectElement>("Currency");
    expect(select.value).toBe("eur");

    fireEvent.change(select, { target: { value: "gbp" } });

    expect(document.cookie).toContain("gumroad_buyer_currency=gbp");
    const target = new URL(String(assign.mock.calls[0]?.[0]));
    expect(target.searchParams.get("currency")).toBeNull();
    expect(target.searchParams.get("foo")).toBe("bar");
    expect(target.pathname).toBe("/l/demo");
  });

  it("initializes from an existing cookie preference", () => {
    document.cookie = "gumroad_buyer_currency=eur; path=/";
    render(<FooterCurrencySelector />);

    expect(screen.getByLabelText<HTMLSelectElement>("Currency").value).toBe("eur");
  });

  it("says so when the product's price did not render in the selected currency", () => {
    document.cookie = "gumroad_buyer_currency=gbp; path=/";
    render(<FooterCurrencySelector detectedCurrency="gbp" shownCurrency="usd" />);

    expect(screen.getByText("Not available for this product — showing $ (US Dollars)")).toBeTruthy();
  });

  it("stays quiet when the product's price did render in the selected currency", () => {
    document.cookie = "gumroad_buyer_currency=gbp; path=/";
    render(<FooterCurrencySelector shownCurrency="gbp" />);

    expect(screen.queryByText(/Not available for this product/u)).toBeNull();
  });

  it("stays quiet on pages that report no focal price", () => {
    document.cookie = "gumroad_buyer_currency=gbp; path=/";
    render(<FooterCurrencySelector />);

    expect(screen.queryByText(/Not available for this product/u)).toBeNull();
  });

  // The old document still describes the old currency, so the mismatch means nothing yet.
  it("does not claim unavailability while the reload is in flight", () => {
    vi.spyOn(window.location, "assign").mockImplementation(() => {});
    render(<FooterCurrencySelector detectedCurrency="usd" shownCurrency="usd" />);

    fireEvent.change(screen.getByLabelText("Currency"), { target: { value: "gbp" } });

    expect(screen.queryByText(/Not available for this product/u)).toBeNull();
  });
});
