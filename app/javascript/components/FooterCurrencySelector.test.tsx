// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { FooterCurrencySelector } from "$app/components/FooterCurrencySelector";

afterEach(() => {
  cleanup();
  document.cookie = "gumroad_buyer_currency=; path=/; max-age=0";
  window.history.replaceState({}, "", "/");
});

describe("FooterCurrencySelector", () => {
  it("defaults to detected and writes the cookie on change", () => {
    const reload = vi.spyOn(window.location, "reload").mockImplementation(() => {});
    render(<FooterCurrencySelector />);

    const select = screen.getByLabelText<HTMLSelectElement>("Currency");
    expect(select.value).toBe("");

    fireEvent.change(select, { target: { value: "gbp" } });

    expect(document.cookie).toContain("gumroad_buyer_currency=gbp");
    expect(reload).toHaveBeenCalled();
  });

  it("initializes from an existing cookie preference", () => {
    document.cookie = "gumroad_buyer_currency=eur; path=/";
    render(<FooterCurrencySelector />);

    expect(screen.getByLabelText<HTMLSelectElement>("Currency").value).toBe("eur");
  });

  it("clears the cookie when switching back to detected", () => {
    vi.spyOn(window.location, "reload").mockImplementation(() => {});
    document.cookie = "gumroad_buyer_currency=eur; path=/";
    render(<FooterCurrencySelector />);

    fireEvent.change(screen.getByLabelText("Currency"), { target: { value: "" } });

    expect(document.cookie).not.toContain("gumroad_buyer_currency=eur");
  });
});
