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
  it("defaults to detected and writes the cookie on change", () => {
    const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});
    render(<FooterCurrencySelector />);

    const select = screen.getByLabelText<HTMLSelectElement>("Currency");
    expect(select.value).toBe("");

    fireEvent.change(select, { target: { value: "gbp" } });

    expect(document.cookie).toContain("gumroad_buyer_currency=gbp");
    expect(assign).toHaveBeenCalled();
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

  it("clears the cookie when switching back to detected", () => {
    vi.spyOn(window.location, "assign").mockImplementation(() => {});
    document.cookie = "gumroad_buyer_currency=eur; path=/";
    render(<FooterCurrencySelector />);

    fireEvent.change(screen.getByLabelText("Currency"), { target: { value: "" } });

    expect(document.cookie).not.toContain("gumroad_buyer_currency=eur");
  });
});
