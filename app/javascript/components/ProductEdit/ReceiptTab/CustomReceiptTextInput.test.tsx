// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CustomReceiptTextInput } from "$app/components/ProductEdit/ReceiptTab/CustomReceiptTextInput";

afterEach(cleanup);

// The regression these tests guard against: the textarea enforces `maxLength` by silently refusing
// further input. A seller pasting a long draft sees it appear cut off mid-sentence with nothing
// explaining why, so the field has to state the limit and how much of it is already used.
describe("CustomReceiptTextInput", () => {
  it("shows the character limit even when the field is empty", () => {
    render(<CustomReceiptTextInput value={null} onChange={vi.fn()} maxLength={500} />);

    expect(screen.getByText(/0 of 500 characters used/u)).toBeTruthy();
  });

  it("counts the characters already entered", () => {
    render(<CustomReceiptTextInput value={"a".repeat(120)} onChange={vi.fn()} maxLength={500} />);

    expect(screen.getByText(/120 of 500 characters used/u)).toBeTruthy();
  });

  it("reports the limit as fully used once the value reaches it", () => {
    render(<CustomReceiptTextInput value={"a".repeat(500)} onChange={vi.fn()} maxLength={500} />);

    expect(screen.getByText(/500 of 500 characters used/u)).toBeTruthy();
  });

  it("caps typed input at the limit so nothing beyond it is submitted", () => {
    const onChange = vi.fn();
    render(<CustomReceiptTextInput value="" onChange={onChange} maxLength={5} />);

    const textarea = screen.getByLabelText("Custom message");
    // maxLength is what the browser enforces, so assert it is wired through rather than relying on
    // happy-dom to reproduce native truncation.
    expect(textarea.getAttribute("maxlength")).toBe("5");
    fireEvent.change(textarea, { target: { value: "abcde" } });

    expect(onChange).toHaveBeenCalledWith("abcde");
    expect(screen.getByText(/of 5 characters used/u)).toBeTruthy();
  });
});
