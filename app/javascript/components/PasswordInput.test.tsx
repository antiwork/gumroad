// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PasswordInput } from "$app/components/PasswordInput";

afterEach(cleanup);
const value = "Example password";

describe("PasswordInput visibility control", () => {
  it("renders a focusable non-submitting button", () => {
    render(
      <form>
        <PasswordInput aria-label="Password" value={value} onChange={vi.fn()} />
      </form>,
    );
    const button = screen.getByRole<HTMLButtonElement>("button", { name: "Show password" });
    expect(button.tagName).toBe("BUTTON");
    expect(button.type).toBe("button");
    expect(button.tabIndex).toBe(0);
  });

  it("preserves the input's explicit tab order", () => {
    render(<PasswordInput value={value} onChange={vi.fn()} tabIndex={1} />);
    expect(screen.getByRole("button", { name: "Show password" }).tabIndex).toBe(1);
  });

  it("toggles visibility and its accessible state without changing the value", () => {
    render(<PasswordInput aria-label="Password" value={value} onChange={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: "Show password" }));
    expect(screen.getByLabelText<HTMLInputElement>("Password").type).toBe("text");
    expect(screen.getByRole("button", { name: "Hide password" }).getAttribute("aria-pressed")).toBe("true");
    fireEvent.click(screen.getByRole("button", { name: "Hide password" }));
    expect(screen.getByLabelText<HTMLInputElement>("Password").type).toBe("password");
    expect(screen.getByLabelText<HTMLInputElement>("Password").value).toBe(value);
    expect(screen.getByRole("button", { name: "Show password" }).getAttribute("aria-pressed")).toBe("false");
  });

  it("disables the visibility button when the input is disabled", () => {
    render(<PasswordInput disabled aria-label="Password" value={value} onChange={vi.fn()} />);
    const button = screen.getByRole<HTMLButtonElement>("button", { name: "Show password" });
    expect(button.disabled).toBe(true);
    button.click();
    expect(screen.getByLabelText<HTMLInputElement>("Password").type).toBe("password");
  });

  it("keeps the input ref and attributes intact", () => {
    const ref = React.createRef<HTMLInputElement>();
    render(
      <PasswordInput
        ref={ref}
        aria-label="Password"
        name="password"
        autoComplete="new-password"
        value={value}
        onChange={vi.fn()}
      />,
    );
    expect(ref.current).toBe(screen.getByLabelText("Password"));
    expect(ref.current?.name).toBe("password");
    expect(ref.current?.autocomplete).toBe("new-password");
  });
});
