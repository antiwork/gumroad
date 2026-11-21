// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CountrySelectionModal } from "$app/components/CountrySelectionModal";

const { get } = vi.hoisted(() => ({ get: vi.fn() }));
vi.mock("@inertiajs/react", () => ({ router: { get } }));

afterEach(() => {
  cleanup();
  get.mockClear();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("CountrySelectionModal", () => {
  it("returns to the dashboard when session storage is blocked", () => {
    vi.stubGlobal("Routes", { dashboard_path: () => "/dashboard" });
    vi.spyOn(window, "sessionStorage", "get").mockImplementation(() => {
      throw new DOMException("Storage unavailable", "SecurityError");
    });
    render(<CountrySelectionModal country="US" countries={{ US: "United States" }} />);

    fireEvent.click(screen.getByRole("button", { name: "Close" }));

    expect(get).toHaveBeenCalledExactlyOnceWith("/dashboard");
  });

  it("goes back when a previous route is available", () => {
    vi.stubGlobal("sessionStorage", { getItem: () => "/products" });
    const back = vi.spyOn(window.history, "back").mockImplementation(() => {});
    render(<CountrySelectionModal country="US" countries={{ US: "United States" }} />);

    fireEvent.click(screen.getByRole("button", { name: "Close" }));

    expect(back).toHaveBeenCalledOnce();
    expect(get).not.toHaveBeenCalled();
  });

  it("makes each requirement a full-width interactive row", () => {
    render(<CountrySelectionModal country="US" countries={{ US: "United States" }} />);

    const requirement = screen.getByLabelText<HTMLInputElement>(
      "I can provide a valid, government-issued photo ID when my payouts are due",
    );
    const row = requirement.closest("label");

    expect(row?.className).toContain("w-full");
    expect(row?.className).toContain("hover:bg-active-bg");
    expect(row?.className).toContain("focus-within:ring-1");
    if (!row) throw new Error("Expected the requirement checkbox to be wrapped by a label");

    fireEvent.click(row);
    expect(requirement.checked).toBe(true);
  });

  it("explains why Save is unavailable until every requirement is checked", () => {
    render(<CountrySelectionModal country="US" countries={{ US: "United States" }} />);

    const save = screen.getByRole("button", { name: "Save" });
    expect(save.hasAttribute("disabled")).toBe(true);
    const hint = screen.getByText("Check both statements above to enable Save.");
    expect(hint.className).not.toContain("invisible");

    for (const checkbox of screen.getAllByRole("checkbox")) fireEvent.click(checkbox);

    expect(save.hasAttribute("disabled")).toBe(false);
    // The hint stays mounted (hidden, not removed) so checking a box doesn't reflow the modal.
    expect(hint.className).toContain("invisible");
    expect(hint.getAttribute("aria-hidden")).toBe("true");
  });
});
