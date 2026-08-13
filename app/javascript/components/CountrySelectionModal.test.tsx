// @vitest-environment happy-dom
import { fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { CountrySelectionModal } from "$app/components/CountrySelectionModal";

afterEach(() => document.body.replaceChildren());

describe("CountrySelectionModal", () => {
  it("makes each requirement a full-width interactive row", () => {
    render(<CountrySelectionModal country="US" countries={{ US: "United States" }} />);

    const requirement = screen.getByLabelText<HTMLInputElement>("I have a valid, government-issued photo ID");
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
