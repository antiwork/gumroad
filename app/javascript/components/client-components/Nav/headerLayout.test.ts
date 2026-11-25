// @vitest-environment happy-dom
import { afterEach, describe, expect, it } from "vitest";

import { currentHeaderLayout, headerHeightClass } from "$app/components/client-components/Nav/headerLayout";

afterEach(() => {
  window.sessionStorage.clear();
  window.history.replaceState({}, "", "/dashboard");
});

describe("currentHeaderLayout", () => {
  it("is the two-row layout unless another is asked for", () => {
    expect(currentHeaderLayout()).toBe("subnav");
  });

  it("takes the layout from the address and keeps it for later pages in the tab", () => {
    window.history.replaceState({}, "", "/dashboard?header=bar");
    expect(currentHeaderLayout()).toBe("bar");

    window.history.replaceState({}, "", "/products");
    expect(currentHeaderLayout()).toBe("bar");
  });

  it("ignores a layout it does not know", () => {
    window.history.replaceState({}, "", "/dashboard?header=sideways");

    expect(currentHeaderLayout()).toBe("subnav");
  });
});

describe("headerHeightClass", () => {
  // Viewport-tall panes subtract this, so it has to match the rows each layout draws.
  it("is one row for the bar and two for the rest", () => {
    expect(headerHeightClass("bar")).toBe("lg:[--dashboard-header-height:4rem]");
    expect(headerHeightClass("subnav-centered")).toBe("lg:[--dashboard-header-height:7rem]");
  });
});
