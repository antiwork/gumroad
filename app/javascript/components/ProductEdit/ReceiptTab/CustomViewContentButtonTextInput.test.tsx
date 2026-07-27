// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CustomViewContentButtonTextInput } from "$app/components/ProductEdit/ReceiptTab/CustomViewContentButtonTextInput";

afterEach(cleanup);

// This field always stated its limit, but as a static "max N characters" and with no programmatic
// association. It sits directly above the Custom message field in the same form, so both now use the
// same running-count wording and both associate the description with their input.
describe("CustomViewContentButtonTextInput", () => {
  it("shows a running character count rather than a static maximum", () => {
    render(<CustomViewContentButtonTextInput value={"a".repeat(12)} onChange={vi.fn()} maxLength={100} />);

    expect(screen.getByText(/12 of 100 characters used/u)).toBeTruthy();
    expect(screen.queryByText(/max 100 characters/u)).toBeNull();
  });

  it("associates the limit with the input for screen readers", () => {
    render(<CustomViewContentButtonTextInput value={null} onChange={vi.fn()} maxLength={100} />);

    const input = screen.getByLabelText("Button text");
    const describedBy = input.getAttribute("aria-describedby");
    expect(describedBy).toBeTruthy();
    expect(document.getElementById(describedBy ?? "")?.textContent).toContain("of 100 characters used");
  });

  it("keeps the count in step with edits", () => {
    const Controlled = () => {
      const [value, setValue] = React.useState("");
      return <CustomViewContentButtonTextInput value={value} onChange={setValue} maxLength={100} />;
    };
    render(<Controlled />);

    const input = screen.getByLabelText("Button text");
    expect(input.getAttribute("maxlength")).toBe("100");
    expect(screen.getByText(/0 of 100 characters used/u)).toBeTruthy();

    fireEvent.change(input, { target: { value: "Start here" } });
    expect(screen.getByText(/10 of 100 characters used/u)).toBeTruthy();
  });
});
