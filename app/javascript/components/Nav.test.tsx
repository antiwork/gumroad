// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it } from "vitest";

import { Nav, NavSection } from "$app/components/Nav";

// Routes is a global injected by js-routes in the app; the nav's logo links need it.
beforeAll(() => {
  Object.assign(globalThis, { Routes: { root_url: () => "/" } });
});

afterEach(cleanup);

const renderNav = () =>
  render(
    <Nav title="Dashboard" footer={<a href="/settings">Settings</a>}>
      <NavSection>
        <a href="/products">Products</a>
      </NavSection>
      <NavSection>
        <a href="/discover">Discover</a>
      </NavSection>
    </Nav>,
  );

describe("Nav", () => {
  it("scrolls only the link list, so the footer stays visible when the links overflow", () => {
    renderNav();

    const nav = screen.getByRole("navigation", { name: "Main" });
    const scrollRegion = nav.querySelector(".overflow-y-auto");

    expect(scrollRegion).not.toBeNull();
    expect(scrollRegion?.contains(screen.getByRole("link", { name: "Products" }))).toBe(true);
    // The footer sitting outside the scroll region is the whole fix: while it was inside, it
    // scrolled out of view exactly when the list was long enough to need scrolling.
    expect(scrollRegion?.contains(screen.getByRole("link", { name: "Settings" }))).toBe(false);
  });

  it("does not scroll the nav as a whole", () => {
    renderNav();

    expect(screen.getByRole("navigation", { name: "Main" }).className).not.toContain("overflow-y-auto");
  });
});
