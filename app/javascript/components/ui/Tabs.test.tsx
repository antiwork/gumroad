// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { Tab, Tabs } from "$app/components/ui/Tabs";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

const rect = (left: number, right: number) => new DOMRect(left, 0, right - left, 0);

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
