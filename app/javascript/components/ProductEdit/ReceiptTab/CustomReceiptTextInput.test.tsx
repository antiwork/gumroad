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

  it("associates the limit with the textarea for screen readers", () => {
    render(<CustomReceiptTextInput value={null} onChange={vi.fn()} maxLength={500} />);

    const textarea = screen.getByLabelText("Custom message");
    const describedBy = textarea.getAttribute("aria-describedby");
    expect(describedBy).toBeTruthy();
    // The description carries the limit, so a non-visual user gets it on focus rather than only
    // discovering the cap when input stops.
    expect(document.getElementById(describedBy ?? "")?.textContent).toContain("of 500 characters used");
  });

  it("keeps the count in step with edits, and never past the limit the textarea enforces", () => {
    // The component is controlled, so drive it through a stateful wrapper: that is what proves the
    // count tracks real edits rather than just rendering whatever was passed in once.
    const Controlled = () => {
      const [value, setValue] = React.useState("");
      return <CustomReceiptTextInput value={value} onChange={setValue} maxLength={5} />;
    };
    render(<Controlled />);

    const textarea = screen.getByLabelText("Custom message");
    // The browser enforces maxLength on the same JS string length the counter displays, so the two
    // can never disagree about when the seller has run out of room.
    expect(textarea.getAttribute("maxlength")).toBe("5");
    expect(screen.getByText(/0 of 5 characters used/u)).toBeTruthy();

    fireEvent.change(textarea, { target: { value: "abc" } });
    expect(screen.getByText(/3 of 5 characters used/u)).toBeTruthy();

    fireEvent.change(textarea, { target: { value: "abcde" } });
    expect(screen.getByText(/5 of 5 characters used/u)).toBeTruthy();
  });
});
