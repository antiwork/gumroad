// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { selectAdjacentRadio } from "$app/utils/radioGroupKeyboard";

import { Button } from "$app/components/Button";
import { Tab, Tabs } from "$app/components/ui/Tabs";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

const rect = (left: number, right: number) => new DOMRect(left, 0, right - left, 0);

const RadioGroup = ({
  values,
  initial = null,
  disabled = [],
  onSelect,
}: {
  values: string[];
  initial?: string | null;
  disabled?: string[];
  onSelect?: () => void;
}) => {
  const [selected, setSelected] = React.useState(initial);
  return (
    <Tabs role="radiogroup" aria-label="Version">
      {values.map((value) => (
        <Tab key={value} isSelected={selected === value} asChild>
          <Button
            role="radio"
            aria-checked={selected === value}
            disabled={disabled.includes(value)}
            onClick={() => {
              onSelect?.();
              setSelected(value);
            }}
          >
            {value}
          </Button>
        </Tab>
      ))}
    </Tabs>
  );
};

const radio = (name: string) => screen.getByRole("radio", { name });
const tabIndexes = () => screen.getAllByRole("radio").map((element) => element.tabIndex);
const checked = (name: string) => radio(name).getAttribute("aria-checked");

describe("Tabs", () => {
  it("scrolls a selected tab past the right edge into view", () => {
    vi.spyOn(Element.prototype, "getBoundingClientRect").mockImplementation(function (this: Element) {
      if (this.getAttribute("role") === "tablist") return rect(0, 300);
      if (this.getAttribute("aria-selected") === "true") return rect(280, 400);
      return rect(0, 100);
    });

    render(
      <Tabs>
        <Tab isSelected={false}>All products</Tab>
        <Tab isSelected>Piracy reports</Tab>
      </Tabs>,
    );

    expect(screen.getByRole("tablist").scrollLeft).toBe(100);
  });

  it("leaves the row alone when the selected tab is already visible", () => {
    vi.spyOn(Element.prototype, "getBoundingClientRect").mockImplementation(function (this: Element) {
      if (this.getAttribute("role") === "tablist") return rect(0, 300);
      return rect(0, 100);
    });

    render(
      <Tabs>
        <Tab isSelected>All products</Tab>
      </Tabs>,
    );

    expect(screen.getByRole("tablist").scrollLeft).toBe(0);
  });
});

describe("Tabs radiogroup", () => {
  it("keeps one tab stop per group: the checked radio", () => {
    render(<RadioGroup values={["One", "Two", "Three"]} initial="Two" />);

    expect(tabIndexes()).toEqual([-1, 0, -1]);
  });

  it("falls back to the first radio when nothing is checked", () => {
    render(<RadioGroup values={["One", "Two", "Three"]} />);

    expect(tabIndexes()).toEqual([0, -1, -1]);
  });

  it("skips disabled radios when picking the tab stop", () => {
    render(<RadioGroup values={["One", "Two"]} disabled={["One"]} />);

    expect(tabIndexes()).toEqual([-1, 0]);
  });

  it("moves focus and selection with the arrow keys", () => {
    render(<RadioGroup values={["One", "Two", "Three"]} initial="One" />);

    fireEvent.keyDown(radio("One"), { key: "ArrowDown" });
    expect(document.activeElement).toBe(radio("Two"));
    expect(checked("Two")).toBe("true");
    expect(checked("One")).toBe("false");
    expect(tabIndexes()).toEqual([-1, 0, -1]);

    fireEvent.keyDown(radio("Two"), { key: "ArrowUp" });
    expect(document.activeElement).toBe(radio("One"));

    fireEvent.keyDown(radio("One"), { key: "ArrowRight" });
    expect(document.activeElement).toBe(radio("Two"));
  });

  it("wraps around the ends and jumps with Home and End", () => {
    render(<RadioGroup values={["One", "Two", "Three"]} initial="One" />);

    fireEvent.keyDown(radio("One"), { key: "ArrowLeft" });
    expect(document.activeElement).toBe(radio("Three"));

    fireEvent.keyDown(radio("Three"), { key: "Home" });
    expect(document.activeElement).toBe(radio("One"));

    fireEvent.keyDown(radio("One"), { key: "End" });
    expect(document.activeElement).toBe(radio("Three"));

    fireEvent.keyDown(radio("Three"), { key: "ArrowUp" });
    expect(document.activeElement).toBe(radio("Two"));
    expect(checked("Two")).toBe("true");
  });

  it("skips disabled radios while arrowing", () => {
    render(<RadioGroup values={["One", "Two", "Three"]} initial="One" disabled={["Two"]} />);

    fireEvent.keyDown(radio("One"), { key: "ArrowDown" });

    expect(document.activeElement).toBe(radio("Three"));
    expect(checked("Three")).toBe("true");
  });

  it("does not re-activate the radio the buyer is already on", () => {
    const onSelect = vi.fn();
    render(<RadioGroup values={["One", "Two"]} initial="One" onSelect={onSelect} />);

    fireEvent.keyDown(radio("One"), { key: "Home" });
    expect(onSelect).not.toHaveBeenCalled();

    fireEvent.keyDown(radio("One"), { key: "ArrowUp" });
    expect(onSelect).toHaveBeenCalledTimes(1);

    fireEvent.keyDown(radio("Two"), { key: "ArrowDown" });
    expect(onSelect).toHaveBeenCalledTimes(2);

    fireEvent.keyDown(radio("One"), { key: "End" });
    expect(onSelect).toHaveBeenCalledTimes(3);

    fireEvent.keyDown(radio("Two"), { key: "End" });
    expect(onSelect).toHaveBeenCalledTimes(3);
  });

  it("does not re-activate a native radio input that is already checked", () => {
    const onClick = vi.fn();
    render(
      <div role="radiogroup" onKeyDown={selectAdjacentRadio}>
        <input type="radio" role="radio" name="size" aria-label="Small" defaultChecked onClick={onClick} />
        <input type="radio" role="radio" name="size" aria-label="Large" />
      </div>,
    );

    fireEvent.keyDown(screen.getByRole("radio", { name: "Small" }), { key: "Home" });
    expect(onClick).not.toHaveBeenCalled();
  });

  it("leaves Alt, Ctrl and Meta arrow shortcuts to the browser", () => {
    render(<RadioGroup values={["One", "Two"]} initial="One" />);
    radio("One").focus();

    for (const modifier of ["altKey", "ctrlKey", "metaKey"]) {
      const notCancelled = fireEvent.keyDown(radio("One"), { key: "ArrowRight", [modifier]: true });

      expect(notCancelled).toBe(true);
      expect(document.activeElement).toBe(radio("One"));
      expect(checked("One")).toBe("true");
    }
  });

  it("leaves a nested radiogroup's radios to that group", () => {
    render(
      <Tabs role="radiogroup" aria-label="Outer">
        <Tab isSelected asChild>
          <Button role="radio" aria-checked>
            One
          </Button>
        </Tab>
        <div role="radiogroup" aria-label="Inner">
          <Button role="radio" aria-checked={false}>
            Nested
          </Button>
        </div>
        <Tab isSelected={false} asChild>
          <Button role="radio" aria-checked={false}>
            Two
          </Button>
        </Tab>
      </Tabs>,
    );

    expect(radio("Nested").hasAttribute("tabindex")).toBe(false);

    fireEvent.keyDown(radio("One"), { key: "ArrowDown" });
    expect(document.activeElement).toBe(radio("Two"));
  });

  it("leaves a tablist's tabs alone", () => {
    render(
      <Tabs>
        <Tab isSelected={false}>All products</Tab>
        <Tab isSelected>Piracy reports</Tab>
      </Tabs>,
    );
    const allProducts = screen.getByRole("tab", { name: "All products" });
    const piracyReports = screen.getByRole("tab", { name: "Piracy reports" });

    expect(allProducts.hasAttribute("tabindex")).toBe(false);
    expect(piracyReports.hasAttribute("tabindex")).toBe(false);

    fireEvent.keyDown(allProducts, { key: "ArrowRight" });

    expect(allProducts.getAttribute("aria-selected")).toBe("false");
    expect(piracyReports.getAttribute("aria-selected")).toBe("true");
  });
});

describe("Tabs hover halo", () => {
  // The buttons variant lifts the tab up and left, so it has to carry the halo that keeps a pointer
  // resting on its right or bottom edge inside it.
  it("pairs the lift with the halo", () => {
    render(
      <Tabs variant="buttons">
        <Tab isSelected={false}>All products</Tab>
        <Tab isSelected>Piracy reports</Tab>
      </Tabs>,
    );

    const tab = screen.getByRole("tab", { name: "All products" });

    expect(tab.className).toContain("not-active:hover:-translate-1");
    expect(tab.className.split(" ")).toContain("lift-halo");
    // A Button inside the tab sets the halo to the store's offset, while the tab's `-translate-1` is the
    // lift that applies, so the halo is pinned back to that lift under the same condition.
    expect(tab.className).toContain("not-active:hover:[--lift-halo-offset:var(--spacing)]");
  });
});
