// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { Select } from "$app/components/Select";

const option = { id: "one", label: "One" };
afterEach(cleanup);

describe("Select action buttons", () => {
  it.each([false, true])("keeps isMulti=%s actions out of a form's default submit buttons", (isMulti) => {
    render(
      <form aria-label="Editor">
        <Select isMulti={isMulti} isClearable value={isMulti ? [option] : option} options={[option]} />
      </form>,
    );

    expect(screen.getByRole("form").querySelectorAll('button:not([type="button"]):not([type="reset"])')).toHaveLength(
      0,
    );
  });

  it.each(["Enter", " "])("clears the selection with %s without opening the menu", (key) => {
    const onChange = vi.fn();
    render(<Select isMulti={false} isClearable value={option} options={[option]} onChange={onChange} />);
    const button = screen.getByLabelText("Clear value");

    // Emulate the native activation only when the keydown was not canceled. Real Chrome QA
    // separately covers implicit form submission, which happy-dom does not implement.
    if (fireEvent.keyDown(button, { key })) fireEvent.click(button);

    expect(onChange).toHaveBeenCalledOnce();
    expect(onChange).toHaveBeenCalledWith(null, expect.objectContaining({ action: "clear" }));
    expect(screen.queryByRole("option")).toBeNull();
    // The clear button unmounts with the value it cleared, so focus goes back to the control's input.
    expect(document.activeElement).toBe(screen.getByRole("combobox"));
  });

  it.each(["Enter", " "])("removes a selected tag with %s without opening the menu", (key) => {
    const onChange = vi.fn();
    render(<Select isMulti value={[option]} options={[option]} onChange={onChange} />);
    const button = screen.getByRole("button", { name: "One" });

    if (fireEvent.keyDown(button, { key })) fireEvent.click(button);

    expect(onChange).toHaveBeenCalledOnce();
    expect(onChange).toHaveBeenCalledWith([], expect.objectContaining({ action: "remove-value" }));
    expect(screen.queryByRole("option")).toBeNull();
  });

  it("keeps mouse clearing working", () => {
    const onChange = vi.fn();
    render(<Select isMulti={false} isClearable value={option} options={[option]} onChange={onChange} />);
    const button = screen.getByLabelText("Clear value");
    fireEvent.mouseDown(button, { button: 0 });
    fireEvent.click(button, { detail: 1 });
    expect(onChange).toHaveBeenCalledOnce();
    expect(onChange).toHaveBeenCalledWith(null, expect.objectContaining({ action: "clear" }));
  });

  it("keeps touch clearing working", () => {
    const onChange = vi.fn();
    render(<Select isMulti={false} isClearable value={option} options={[option]} onChange={onChange} />);
    fireEvent.touchEnd(screen.getByLabelText("Clear value"));
    expect(onChange).toHaveBeenCalledWith(null, expect.objectContaining({ action: "clear" }));
  });

  it("keeps mouse tag removal working", () => {
    const onChange = vi.fn();
    render(<Select isMulti value={[option]} options={[option]} onChange={onChange} />);
    fireEvent.click(screen.getByRole("button", { name: "One" }));
    expect(onChange).toHaveBeenCalledWith([], expect.objectContaining({ action: "remove-value" }));
  });

  it("disables tag buttons in a disabled select", () => {
    render(<Select isMulti isDisabled value={[option]} options={[option]} />);
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "One" }).disabled).toBe(true);
  });

  it("keeps keyboard option selection working", () => {
    const onChange = vi.fn();
    render(<Select isMulti={false} options={[option]} onChange={onChange} />);
    const input = screen.getByRole("combobox");
    fireEvent.focus(input);
    fireEvent.keyDown(input, { key: "ArrowDown" });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(onChange).toHaveBeenCalledWith(option, expect.objectContaining({ action: "select-option" }));
  });
});
