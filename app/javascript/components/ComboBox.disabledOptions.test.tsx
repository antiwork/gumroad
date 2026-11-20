// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { ComboBox } from "$app/components/ComboBox";

afterEach(cleanup);

const setup = (disabled: boolean[]) => {
  const onSelect = vi.fn<(option: string) => void>();
  let inspections = 0;
  render(
    <ComboBox
      options={disabled.map((_, index) => `Option ${index + 1}`)}
      input={(props) => <div {...props}>Choose</div>}
      option={(item, props, index) => (
        <div
          {...props}
          ref={(node) => {
            props.ref(node);
            if (node) {
              Object.defineProperty(node, "inert", {
                configurable: true,
                // Let the old infinite loop escape so it fails assertions, not the test runner.
                get: () => (++inspections > disabled.length ? false : disabled[index]),
              });
            }
          }}
          onClick={() => onSelect(item)}
        >
          {item}
        </div>
      )}
    />,
  );
  fireEvent.click(screen.getByRole("combobox"));
  return { onSelect, inspections: () => inspections };
};

describe("ComboBox disabled-option navigation", () => {
  it.each([
    ["ArrowDown", [true, false], "Option 2"],
    ["ArrowUp", [false, true], "Option 1"],
  ] as const)("skips a disabled option with %s", (key, disabled, expected) => {
    const state = setup([...disabled]);
    fireEvent.keyUp(window, { key });
    fireEvent.keyUp(window, { key: "Enter" });
    expect(state.onSelect).toHaveBeenCalledWith(expected);
    expect(state.inspections()).toBeLessThanOrEqual(disabled.length);
  });

  it("stops after one pass when every option is disabled", () => {
    const state = setup([true, true]);
    fireEvent.keyUp(window, { key: "ArrowDown" });
    expect(state.inspections()).toBeLessThanOrEqual(2);
    expect(
      screen.getAllByRole("option", { hidden: true }).every((option) => !option.className.includes("bg-primary")),
    ).toBe(true);
  });

  it("handles an empty list", () => {
    const state = setup([]);
    fireEvent.keyUp(window, { key: "ArrowDown" });
    fireEvent.keyUp(window, { key: "Enter" });
    expect(state.onSelect).not.toHaveBeenCalled();
    expect(state.inspections()).toBe(0);
  });

  it("wraps backwards past disabled options at the end of the list", () => {
    const { onSelect } = setup([false, false, true]);
    fireEvent.keyUp(window, { key: "ArrowDown" });
    fireEvent.keyUp(window, { key: "ArrowUp" });
    fireEvent.keyUp(window, { key: "Enter" });
    expect(onSelect).toHaveBeenCalledExactlyOnceWith("Option 2");
  });

  it("keeps normal option selection working", () => {
    const state = setup([false, false]);
    fireEvent.keyUp(window, { key: "ArrowDown" });
    fireEvent.keyUp(window, { key: "Enter" });
    expect(state.onSelect).toHaveBeenCalledWith("Option 1");
  });
});
