// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { ComboBox } from "$app/components/ComboBox";

afterEach(cleanup);

const setup = () => {
  const onSelect = vi.fn<(option: string) => void>();
  render(
    <ComboBox
      options={["First", "Second", "Third"]}
      input={(props) => <div {...props}>Choose</div>}
      option={(item, props) => (
        <div {...props} onClick={() => onSelect(item)}>
          {item}
        </div>
      )}
    />,
  );
  fireEvent.click(screen.getByRole("combobox"));
  return onSelect;
};
const press = (key: string) => fireEvent.keyUp(window, { key });
const activeOption = () =>
  document.getElementById(screen.getByRole("combobox").getAttribute("aria-activedescendant") ?? "");

describe("ComboBox keyboard wrapping", () => {
  it("wraps ArrowUp from First to Third and selects it", () => {
    const onSelect = setup();
    press("ArrowDown");
    press("ArrowUp");
    expect(activeOption()?.textContent).toBe("Third");
    press("Enter");
    expect(onSelect).toHaveBeenCalledWith("Third");
  });

  it("references the first highlighted option for assistive technology", () => {
    setup();
    press("ArrowDown");
    const listbox = screen.getByRole("listbox");
    expect(screen.getByRole("combobox").getAttribute("aria-controls")).toBe(listbox.id);
    expect(activeOption()).toBe(within(listbox).getByRole("option", { name: "First" }));
  });

  it("keeps initial ArrowUp selecting the last option", () => {
    const onSelect = setup();
    press("ArrowUp");
    press("Enter");
    expect(onSelect).toHaveBeenCalledWith("Third");
  });

  it("keeps forward wrapping selecting First", () => {
    const onSelect = setup();
    for (let i = 0; i < 4; i++) press("ArrowDown");
    press("Enter");
    expect(onSelect).toHaveBeenCalledWith("First");
  });

  it("keeps Escape closing the list without selecting", () => {
    const onSelect = setup();
    press("ArrowDown");
    press("Escape");
    expect(screen.getByRole("combobox").getAttribute("aria-expanded")).toBe("false");
    expect(activeOption()).toBeNull();
    expect(onSelect).not.toHaveBeenCalled();
  });

  it("keeps mouse selection working", () => {
    const onSelect = setup();
    fireEvent.click(screen.getByText("Second"));
    expect(onSelect).toHaveBeenCalledWith("Second");
  });
});
