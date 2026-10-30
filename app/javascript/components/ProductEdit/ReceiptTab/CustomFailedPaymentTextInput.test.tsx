// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CustomFailedPaymentTextInput } from "$app/components/ProductEdit/ReceiptTab/CustomFailedPaymentTextInput";

afterEach(cleanup);

describe("CustomFailedPaymentTextInput", () => {
  it("shows the character count and plain-text note", () => {
    render(<CustomFailedPaymentTextInput value={"a".repeat(12)} onChange={vi.fn()} maxLength={500} />);

    expect(screen.getByText(/12 of 500 characters used/u)).toBeTruthy();
    expect(screen.getByText(/Plain text only, no links/u)).toBeTruthy();
  });

  it("reports changes", () => {
    const onChange = vi.fn();
    render(<CustomFailedPaymentTextInput value={null} onChange={onChange} maxLength={500} />);

    fireEvent.change(screen.getByLabelText("Failed payment message"), { target: { value: "Hi" } });

    expect(onChange).toHaveBeenCalledWith("Hi");
  });
});
